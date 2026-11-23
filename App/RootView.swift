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
                    // Over the tabs and under every sheet and cover.
                    .overlay { FloatingRemote() }
            case .choosingServer:
                NavigationStack { ServerListView(isRoot: true) }
            case .signedOut, .signingIn, .failed:
                SignInView()
            }
        }
        // Sign-in, the server list and the tabs fade into each other rather than cut (DESIGN §9 layer;
        // Reduce Motion keeps a short fade).
        .animation(reduceMotion ? .linear(duration: 0.12) : .easeOut(duration: 0.22), value: stage)
        .onChange(of: session.state) { _, state in
            // The bar and the live player's cover hang from the tabs; a playback only they showed would play on unseen.
            if state != .ready { session.player.tabsLeft() }
        }
        .fullScreenCover(item: playerCover(overSettings: false), onDismiss: { session.player.dismissed() }) { model in
            PlayerView(model: model, outerTheme: theme, outerScheme: scheme ?? colorScheme)
                // Opened from the mini player bar the player grows out of the bar's picture, and its own
                // pull-down is the way back, so the system's dismissal gesture stays off.
                .miniPlayerZoom(in: sheetNamespace, enabled: session.player.zoomsFromBar && !reduceMotion)
                .interactiveDismissDisabled(session.player.zoomsFromBar)
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
        // Scroll Indicators (DESIGN §8.7) reaches the sheets from here too; the A–Z rail is its own control.
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
        // Linked phones listen and call only while Marquee is up; iOS stops local networking behind it.
        .onChange(of: scenePhase == .background, initial: true) { _, background in
            session.link.setForeground(!background, session: session, themeStore: store)
        }
        .onChange(of: BarInputs(theme: theme, typeSize: typeSize, boldText: legibilityWeight == .bold), initial: true) { _, inputs in
            NavigationBarStyle.apply(inputs.theme, typeSize: inputs.typeSize, boldText: inputs.boldText)
        }
        // The external display's scene is offered once the phone's screen is up and a server is chosen; the
        // remote comes up by itself when glasses or a TV connect while Marquee is open.
        .onChange(of: scenePhase == .active && session.state == .ready, initial: true) { _, ready in
            if ready { session.glasses.phoneReady(session: session, themeStore: store) }
        }
        .onChange(of: session.glasses.showsRemote) { session.glasses.syncRemote() }
        .alert(session.glasses.question, isPresented: Binding(get: { session.glasses.asksToUse }, set: { session.glasses.asksToUse = $0 })) {
            Button("Use as XR Glasses") { session.glasses.answer(.glasses) }
            Button("Use as TV") { session.glasses.answer(.tv) }
            Button("Mirror", role: .cancel) { session.glasses.answer(nil) }
        } message: {
            Text("Marquee shows its own screen on the display, and this iPhone becomes a remote that works without looking at it. The answer is kept for this display; Settings › Big Screen changes it.")
        }
        .modifier(RootDiagnostics(theme: theme, scheme: scheme))
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var toasts = ToastCenter()
    @State private var followUp = DeletionFollowUp()
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sheetZoomNamespace) private var zoomNamespace

    var body: some View {
        let tabs = store.tabLayout.tabs(available: Destination.available(in: session))
        let selection = picked.flatMap { tabs.contains($0) ? $0 : nil } ?? tabs.first ?? .home
        TabView(selection: Binding(get: { selection }, set: { picked = $0 })) {
            ForEach(tabs) { destination in
                Tab(destination.title, systemImage: destination.systemImage, value: destination, role: destination == .search ? .search : nil) {
                    BrowseStack(tab: destination.rawValue) { destination.page() }
                        .miniBarInset(isSelected: destination == selection)
                }
                .badge(destination.badge(in: session))
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewBottomAccessory(isEnabled: showsAccessory) {
            MiniPlayerAccessory(showsRemote: showsRemoteBar)
        }
        .diagPresentation("livetv.player", isPresented: session.player.livePresented != nil)
        .fullScreenCover(item: liveCover, onDismiss: { session.player.liveDismissed() }) { model in
            LivePlayerView(
                model: model, outerTheme: theme, outerScheme: colorScheme,
                close: { session.player.closeLive(model) }, minimise: { session.player.minimise() }
            )
            .miniPlayerZoom(in: zoomNamespace, enabled: session.player.zoomsFromBar && !reduceMotion)
            .interactiveDismissDisabled(session.player.zoomsFromBar)
        }
        // Minimise shrinks the bar while a page scrolls down; Hide is each browse stack's own (BrowseStack).
        // Search keeps the bar still while its results scroll and the keyboard comes and goes.
        .tabBarMinimizeBehavior(store.tabBar == .minimise && selection != .search ? .onScrollDown : .never)
        // Above the environment lines below, which the alert reads.
        .deletionFollowUp()
        .environment(\.tabSelection, TabSelection(tabs: tabs, select: { picked = $0 }))
        .environment(toasts)
        .environment(followUp)
        .environment(session.changes)
        .onChange(of: session.server?.id) { session.changes.forgetDeletions() }
        .onChange(of: selection, initial: true) { _, tab in
            DiagScreen.tab = tab.rawValue
            Diag.event(.nav, "tab", ["tab": tab.rawValue])
        }
        .onChange(of: session.glasses.leaveHint) { _, hint in
            guard let hint else { return }
            toasts.show(hint)
            session.glasses.clearLeaveHint()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { toasts.finish() }
        }
        .environment(\.plexWatchlist, session.plexTV.map { PlexWatchlist(http: $0.http) })
        .environment(\.sessionActions, SessionActions(
            startPlayback: { item, index, fromStart in session.play(item: item, mediaIndex: index, fromStart: fromStart) },
            signInAgain: { session.signOut() },
            canDeleteMedia: session.canDeleteMedia
        ))
    }

    /// The remote's mini bar, which a minimised playback takes the place of.
    private var showsRemoteBar: Bool {
        session.remote.isEnabled && session.remote.access == .miniBar && session.place == .home && !session.glasses.isConnected
    }

    /// The system's bottom accessory: a minimised playback while its bar is slim, else the remote's mini
    /// bar. A taller bar sits in each tab's own inset (`miniBarInset`), as the accessory's glass cannot grow.
    private var showsAccessory: Bool {
        session.player.docked != nil ? store.miniBarHeight == nil : showsRemoteBar
    }

    /// The live player's cover hangs here, over every tab, so the mini player bar can open it from any.
    private var liveCover: Binding<LivePlaybackModel?> {
        let session = session
        return Binding(get: { session.player.livePresented }, set: { session.player.livePresented = $0 })
    }
}

/// What the log needs from the root: the scene's phase, the session's state, the display settings and the
/// window's size as they change, the sheets and covers hung here, and the theme the report sheet and the
/// floating button draw in.
private struct RootDiagnostics: ViewModifier {
    @Environment(AppSession.self) private var session
    @Environment(ThemeStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let theme: Theme
    let scheme: ColorScheme?

    private struct Display: Equatable {
        var theme: Theme
        var scheme: ColorScheme?
        var typeSize: DynamicTypeSize
        var bold: Bool
        var contrast: Bool
        var reduceMotion: Bool
        var reduceTransparency: Bool
    }

    /// The TV remote's link as a word; the cases may carry the paired TV and its keys.
    private var remoteState: String {
        switch session.remote.model.connection {
        case .none: "not-paired"
        case .connecting: "connecting"
        case .connected: "connected"
        case .offline: "offline"
        case .incompatible: "incompatible"
        case .unpaired: "unpaired"
        }
    }

    func body(content: Content) -> some View {
        let display = Display(
            theme: theme, scheme: scheme, typeSize: typeSize, bold: legibilityWeight == .bold, contrast: contrast == .increased,
            reduceMotion: reduceMotion, reduceTransparency: reduceTransparency
        )
        content
            .onChange(of: scenePhase, initial: true) { _, phase in
                Diag.event(.ui, "scene", ["phase": "\(phase)"])
                if phase == .active { ReportButton.shared.sceneReady() }
            }
            .onChange(of: session.state, initial: true) { _, state in
                switch state {
                case .signedOut: Diag.event(.app, "state", ["state": "signed-out"])
                case .signingIn: Diag.event(.app, "state", ["state": "signing-in"])
                case .choosingServer(let servers): Diag.event(.app, "state", ["state": "choosing-server", "servers": servers.count])
                case .ready: Diag.event(.app, "state", ["state": "ready", "server": session.server?.name])
                case .failed(let error): Diag.event(.app, "state", ["state": "failed", "error": error], .warning)
                }
            }
            .onChange(of: display, initial: true) { _, display in
                ReportCenter.shared.theme = display.theme
                ReportCenter.shared.scheme = display.scheme
                ReportCenter.shared.store = store
                Diag.event(.ui, "display", [
                    "theme": display.theme.name, "scheme": display.scheme.map { "\($0)" } ?? "system", "textSize": "\(display.typeSize)",
                    "bold": display.bold, "contrast": display.contrast, "reduceMotion": display.reduceMotion,
                    "reduceTransparency": display.reduceTransparency,
                ])
            }
            // With the safe area, so the keyboard coming and going is not a new size.
            .onGeometryChange(for: CGSize.self) { proxy in
                let insets = proxy.safeAreaInsets
                return CGSize(width: proxy.size.width + insets.leading + insets.trailing, height: proxy.size.height + insets.top + insets.bottom)
            } action: { size in
                Diag.event(.ui, "layout", [
                    "w": Int(size.width), "h": Int(size.height), "orientation": size.width > size.height ? "landscape" : "portrait",
                    "hClass": horizontalSizeClass.map { "\($0)" }, "vClass": verticalSizeClass.map { "\($0)" },
                ])
            }
            .diagPresentation("settings", isPresented: session.showsSettings)
            .diagPresentation("profiles", isPresented: session.showsProfileSwitcher)
            .diagPresentation("remote", isPresented: session.remote.isPresented)
            .diagPresentation("player", isPresented: session.player.presented != nil)
            .diagPresentation("glasses.ask", isPresented: session.glasses.asksToUse)
            .onChange(of: remoteState) { _, state in
                Diag.event(.link, "remote.connection", ["state": state], ["offline", "incompatible", "unpaired"].contains(state) ? .notice : .info)
            }
    }
}
