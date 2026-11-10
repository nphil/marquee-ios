import MarqueeCore
import SwiftUI

/// A place a browse tab's stack can push. `zoomID` names the artwork the push started from, for the
/// zoom transition; one title can sit in several shelves at once, so the id is per shelf.
enum Route: Hashable {
    /// A movie, show, season or episode on the server.
    case item(ratingKey: String, zoomID: String? = nil)
    /// The titles behind a key the server handed out: a shelf's "see all", a collection, a person.
    case hub(key: String, title: String)
    /// A watchlist title, which may or may not be on the server.
    case watchlist(PlexMetadata, zoomID: String? = nil)
    /// A cast or crew member's titles in the libraries.
    case person(id: String, name: String, thumb: String?)
    /// A top-level place without a tab, opened from another page (DESIGN §7).
    case destination(Destination)
    /// A title on Seerr, to request or, once it is in Plex, to play.
    case seerrTitle(SeerrTitle, zoomID: String? = nil)

    var zoomID: String? {
        switch self {
        case .item(_, let zoomID), .watchlist(_, let zoomID), .seerrTitle(_, let zoomID): zoomID
        case .hub, .person, .destination: nil
        }
    }

    /// Where tapping a title goes: a collection lists its titles, anything else opens its detail page.
    static func to(_ item: PlexMetadata, zoomID: String? = nil) -> Route {
        item.type == .collection ? .hub(key: item.key, title: item.title) : .item(ratingKey: item.ratingKey, zoomID: zoomID)
    }
}

/// Pushes a route onto the current tab's stack, for places a NavigationLink cannot sit, such as menus.
struct OpenRouteAction {
    let open: @MainActor (Route) -> Void

    @MainActor
    func callAsFunction(_ route: Route) {
        open(route)
    }
}

extension EnvironmentValues {
    @Entry var openRoute: OpenRouteAction = OpenRouteAction { _ in }
    @Entry var zoomNamespace: Namespace.ID? = nil
}

extension View {
    /// Marks artwork as where its detail page zooms out of and back into. `cornerRadius` matches the
    /// artwork's clip so the shape morphs cleanly.
    func zoomSource(_ id: String?, cornerRadius: CGFloat) -> some View {
        modifier(ZoomSource(id: id, cornerRadius: cornerRadius))
    }
}

private struct ZoomSource: ViewModifier {
    let id: String?
    let cornerRadius: CGFloat
    @Environment(\.zoomNamespace) private var namespace

    func body(content: Content) -> some View {
        if let id, let namespace {
            content.matchedTransitionSource(id: id, in: namespace) { source in
                source.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        } else {
            content
        }
    }
}
