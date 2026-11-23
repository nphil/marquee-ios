import MarqueeCore
import SwiftUI

/// A browse tab's navigation stack (DESIGN §7): its own path, the namespace its artwork zooms in, every
/// page a browse screen can push, the toast overlay above the tab bar and, with Hide chosen, whether
/// the tab bar is away.
struct BrowseStack<Root: View>: View {
    private let root: Root
    /// The tab's name in the diagnostic log.
    private let tab: String

    @State private var path: [Route] = []
    @State private var tabBar = TabBarScroll()
    @Namespace private var zoom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(tab: String = "", @ViewBuilder root: () -> Root) {
        self.tab = tab
        self.root = root()
    }

    var body: some View {
        // The tab holds the stack itself, like Settings; the overlay and environment go on each page.
        // Wrapping the stack in an overlay let the tab lay its first page out at an infinite width, which
        // crashed on its scroll view (CALayerInvalidGeometry, iOS 27.0 simulator).
        NavigationStack(path: $path) {
            root
                .zoomReturnGate(depth: path.count, enabled: !reduceMotion)
                .modifier(StackChrome(zoom: zoom, open: open, tabBar: tabBar))
                .navigationDestination(for: Route.self) { route in
                    RouteDestination(route: route)
                        .modifier(StackChrome(zoom: zoom, open: open, tabBar: tabBar))
                        .modifier(RouteTransition(zoomID: reduceMotion ? nil : route.zoomID, namespace: zoom))
                }
                // The page arriving after a push or a pop shows the tab bar, as a page at its top does.
                .onChange(of: path.count) { tabBar.show(reduceMotion: reduceMotion) }
        }
        .onChange(of: path) { old, new in
            let names = new.map(\.diagName)
            DiagScreen.stacks[tab] = names
            if new.count > old.count {
                Diag.event(.nav, "push", ["tab": tab, "route": names.last, "depth": new.count])
            } else {
                Diag.event(.nav, "pop", ["tab": tab, "to": names.last ?? "root", "depth": new.count])
            }
        }
    }

    private var open: OpenRouteAction {
        OpenRouteAction { path.append($0) }
    }
}

/// What every page of a browse stack carries: the zoom namespace, the push actions, toasts above the tab
/// bar, the stack's Hide state and the tab bar's reach for the floating remote to rest above.
private struct StackChrome: ViewModifier {
    let zoom: Namespace.ID
    let open: OpenRouteAction
    let tabBar: TabBarScroll

    @Environment(\.tabSelection) private var tabSelection
    @Environment(AppSession.self) private var session
    /// How far the tab bar and its accessory reach up from the window's foot, as this page last laid out.
    @State private var bottomInset: CGFloat?

    func body(content: Content) -> some View {
        let tabs = tabSelection
        let open = open
        content
            .overlay(alignment: .bottom) { ToastOverlay() }
            .environment(\.zoomNamespace, zoom)
            .environment(\.openRoute, open)
            .environment(\.openDestination, OpenDestinationAction { destination in
                if tabs.isTab(destination) {
                    tabs.select(destination)
                } else {
                    open(.destination(destination))
                }
            })
            .environment(tabBar)
            .toolbarVisibility(tabBar.hidden ? .hidden : .automatic, for: .tabBar)
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { inset in
                bottomInset = inset
                session.remote.setBottomChrome(inset)
            }
            // A page that comes back, from a push or another tab, is laid out as before, so it says what it
            // last measured.
            .onAppear {
                if let bottomInset { session.remote.setBottomChrome(bottomInset) }
            }
    }
}

/// Zooms from the tapped artwork. Without a source, or under Reduce Motion, the push is the system's own,
/// which follows Prefer Cross-Fade Transitions (DESIGN §9).
private struct RouteTransition: ViewModifier {
    let zoomID: String?
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if let zoomID {
            content.navigationTransition(.zoom(sourceID: zoomID, in: namespace))
        } else {
            content
        }
    }
}

private struct RouteDestination: View {
    let route: Route

    var body: some View {
        switch route {
        case .item(let ratingKey, _):
            DetailView(ratingKey: ratingKey)
        case .hub(let key, let title):
            HubGridView(key: key, title: title)
        case .watchlist(let item, _):
            WatchlistDetailView(item: item)
        case .person(let id, let name, let thumb):
            PersonView(id: id, name: name, thumb: thumb)
        case .destination(let destination):
            destination.page(pushed: true)
        case .seerrTitle(let title, _):
            SeerrTitleView(title: title)
        case .seerrBrowse(let feed):
            SeerrBrowseView(feed: feed)
        }
    }
}

extension View {
    /// After a zoom pops back, iOS holds the source artwork out of the scroll layout while the transition
    /// settles, and a scroll started in that window freezes it for about a second (FB21961572, seen on
    /// iOS 26). Scrolling pauses for 600 ms after each pop so the window is never entered.
    func zoomReturnGate(depth: Int, enabled: Bool) -> some View {
        modifier(ZoomReturnGate(depth: depth, enabled: enabled))
    }
}

private struct ZoomReturnGate: ViewModifier {
    let depth: Int
    let enabled: Bool
    @State private var settling = false
    @State private var release: Task<Void, Never>? = nil

    func body(content: Content) -> some View {
        content
            .scrollDisabled(settling)
            .onChange(of: depth) { old, new in
                guard enabled, new < old else { return }
                settling = true
                // A quick pop, push and pop must not let the first release end the second hold.
                release?.cancel()
                release = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    settling = false
                }
            }
    }
}
