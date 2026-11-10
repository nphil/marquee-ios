import MarqueeCore
import SwiftUI

/// Home (DESIGN §8.1): the rows the profile chose in Home Rows, in its order. Continue Watching shows
/// as 16:9 cards and every other row as a poster shelf. While Watchlist is not a tab its titles follow
/// Continue Watching; while Library is not a tab the title menu opens every place that is not one (§7).
struct HomeView: View {
    @Environment(\.plexLibrary) private var library
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(LibraryChanges.self) private var changes
    @Environment(AppSession.self) private var session
    @Environment(ThemeStore.self) private var store
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.tabSelection) private var tabs
    @Environment(\.openDestination) private var openDestination
    @State private var rows = Remote<[HomeRow]>()
    @State private var editing = false

    var body: some View {
        // Read here, not only inside the row content, so Home redraws on every layout change.
        let layout = session.settings.homeRows
        WidthReader { width in
            RemoteContent(remote: rows) { rows in
                content(layout.arrange(withoutDeleted(rows)), width: width)
            } skeleton: {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s7) {
                        ContinueSkeleton(cardWidth: Self.cardWidth(for: width))
                        Skeleton.Shelf()
                        Skeleton.Shelf()
                    }
                    .padding(.vertical, Space.s3)
                }
                .scrollDisabled(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.canvas)
        .navigationTitle("Home")
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            if session.remote.isEnabled && session.remote.access == .homeButton && session.place == .home {
                ToolbarItem(placement: .topBarTrailing) { TVRemoteButton() }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(placement: .topBarTrailing) { ProfileButton() }
                .sharedBackgroundVisibility(.hidden)
        }
        .modifier(PlacesMenu(places: tabs.isTab(.library) ? [] : store.tabLayout.order.filter {
            !tabs.isTab($0) && $0.isAvailable(in: session)
        }, open: openDestination))
        // A library's hubs are asked for only while one of its rows is shown, so showing one reloads.
        .task(id: LoadKey(library: library?.instance, attempt: rows.attempt, extra: Reload(
            revision: changes.revision,
            libraries: session.settings.homeRows.shownLibraries,
            hidden: session.settings.hiddenLibraries
        ))) {
            await load()
        }
        .sheet(isPresented: $editing) {
            EditHomeSheet()
                .preferredColorScheme(store.presentationScheme(for: theme))
        }
    }

    @ViewBuilder
    private func content(_ arranged: [HomeRow], width: CGFloat) -> some View {
        let shown = arranged.filter { $0.shown && !$0.hub.items.isEmpty }
        if shown.isEmpty, arranged.contains(where: { !$0.hub.items.isEmpty }) {
            EmptyState(
                title: "Every row is hidden",
                message: "Choose the rows Home shows.",
                systemImage: "rectangle.stack",
                action: EmptyState.Action(title: "Edit Home", systemImage: "slider.horizontal.3") { editing = true }
            )
        } else if shown.isEmpty {
            EmptyState(
                title: "Nothing here yet",
                message: "Add some on the server.",
                systemImage: "film.stack",
                action: EmptyState.Action(title: "Refresh", systemImage: "arrow.clockwise") { rows.retry() }
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.s7) {
                    let watchlistShelf = !tabs.isTab(.watchlist)
                    if watchlistShelf, !shown.contains(where: \.isContinueWatching) {
                        WatchlistShelf()
                    }
                    ForEach(shown) { row in
                        let menu = ShelfMenu(hide: { hide(row, in: arranged) }, edit: { editing = true })
                        if row.isContinueWatching {
                            if width > 0 {
                                ContinueShelf(hub: row.hub, title: row.title, cardWidth: Self.cardWidth(for: width), header: menu, setShown: setShown)
                            }
                            if watchlistShelf {
                                WatchlistShelf()
                            }
                        } else {
                            PosterShelf(hub: row.hub, id: row.id, title: row.title, menu: menu)
                        }
                    }
                }
                .padding(.vertical, Space.s3)
            }
            .refreshable { await load() }
            .scrollHeader()
            .tabBarFollowsScroll()
        }
    }

    /// About 82% of a phone's width, so the next card peeks (DESIGN §4.1); on a wide screen (landscape)
    /// about a third, so a card and its caption stay above the floating tab bar (402 pt of height on its
    /// side) and nearly three show.
    private static func cardWidth(for width: CGFloat) -> CGFloat {
        let shown = max(width, 320)
        return (shown * (shown < 600 ? 0.82 : 0.33)).rounded()
    }

    private func load() async {
        guard let library else { return }
        let libraries = session.settings.homeRows.shownLibraries
        let hidden = session.settings.hiddenLibraries
        await rows.load { try await HomeRows.load(from: library, libraries: libraries, hidden: hidden) }
    }

    /// `rows` without the titles deleted this session; a row left empty is not shown.
    private func withoutDeleted(_ rows: [HomeRow]) -> [HomeRow] {
        rows.map { row in
            var row = row
            row.hub.items = changes.shown(row.hub.items)
            return row
        }
    }

    /// Hides a row from its title's long press, with Undo in the toast.
    private func hide(_ row: HomeRow, in arranged: [HomeRow]) {
        guard let index = arranged.firstIndex(where: { $0.id == row.id }) else { return }
        let session = session
        let animation = Motion.spring(reduceMotion: reduceMotion)
        let before = session.settings.homeRows
        var edited = arranged
        edited[index].shown = false
        withAnimation(animation) { session.settings.homeRows.save(edited) }
        toasts.show("\(row.title) hidden", undo: {
            withAnimation(animation) { session.settings.homeRows = before }
        })
    }

    /// Takes a card out of Continue Watching, or puts it back where it was, ahead of the server.
    private func setShown(_ shown: Bool, _ item: PlexMetadata, at index: Int) {
        withAnimation(Motion.spring(reduceMotion: reduceMotion)) {
            rows.update { rows in
                guard let row = rows.firstIndex(where: \.isContinueWatching) else { return }
                rows[row].hub.items.removeAll { $0.ratingKey == item.ratingKey }
                if shown { rows[row].hub.items.insert(item, at: min(index, rows[row].hub.items.count)) }
            }
        }
    }

    private struct Reload: Hashable {
        let revision: Int
        let libraries: Set<String>
        let hidden: Set<String>
    }
}

/// Home's title menu, with every place that is not a tab, while Library is not one either (DESIGN §7).
private struct PlacesMenu: ViewModifier {
    let places: [Destination]
    let open: OpenDestinationAction

    func body(content: Content) -> some View {
        if places.isEmpty {
            content
        } else {
            content.toolbarTitleMenu {
                ForEach(places) { place in
                    Button(place.title, systemImage: place.systemImage) { open(place) }
                }
            }
        }
    }
}

/// The Continue Watching row: snapping 16:9 cards. A tap resumes; a long press offers Details, Mark
/// Watched, Mark Show Watched (on an episode) and Remove from Continue Watching.
private struct ContinueShelf: View {
    let hub: PlexHub
    let title: String
    let cardWidth: CGFloat
    let header: ShelfMenu
    let setShown: @MainActor (Bool, PlexMetadata, Int) -> Void

    @Environment(\.sessionActions) private var session
    @Environment(\.openRoute) private var openRoute
    private let actions = ItemActions()

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            ShelfHeader(title: title, menu: header)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Space.s3) {
                    ForEach(Array(hub.items.enumerated()), id: \.element.id) { index, item in
                        let zoomID = "continue/\(item.ratingKey)"
                        Button {
                            session.play(item)
                        } label: {
                            ContinueCard(item: item, width: cardWidth, zoomID: zoomID)
                        }
                        .buttonStyle(PressButtonStyle(cornerRadius: Radius.card))
                        .contextMenu { menu(item, index: index, zoomID: zoomID) }
                        .accessibilityIdentifier("continue.\(item.ratingKey)")
                        .accessibilityHint("Resumes playback")
                        .accessibilityActions { menu(item, index: index, zoomID: zoomID) }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, Space.inset, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
        }
    }

    @ViewBuilder
    private func menu(_ item: PlexMetadata, index: Int, zoomID: String) -> some View {
        Button("Details", systemImage: "info.circle") {
            openRoute(.item(ratingKey: item.ratingKey, zoomID: zoomID))
        }
        Button("Mark Watched", systemImage: "checkmark.circle") {
            actions.setWatched(true, item) { watched in setShown(!watched, item, index) }
        }
        if item.type == .episode, let show = item.grandparentRatingKey {
            Button("Mark Show Watched", systemImage: "checkmark.circle.fill") {
                // Every card of the show leaves at once, as the server drops its Continue Watching entries.
                let cards = hub.items.enumerated().filter { $0.element.grandparentRatingKey == show }
                actions.setWatched(true, key: show, touching: [], scope: .show) { watched in
                    for card in cards { setShown(!watched, card.element, card.offset) }
                }
            }
        }
        Button("Remove from Continue Watching", systemImage: "minus.circle") {
            actions.removeFromContinueWatching(item) { hidden in setShown(!hidden, item, index) }
        }
    }
}

/// A Continue Watching card: the 16:9 art, then under it, never over it, the progress, the title and
/// "S2 · E5 · 42 min left" (DESIGN §8.1).
private struct ContinueCard: View {
    let item: PlexMetadata
    let width: CGFloat
    let zoomID: String

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            PlexArtView(path: item.cardArtPath, size: CGSize(width: width, height: (width * 9 / 16).rounded()))
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .zoomSource(zoomID, cornerRadius: Radius.card)
            ProgressBar(value: item.progress ?? 0)
                .opacity(item.progress == nil ? 0 : 1)
            VStack(alignment: .leading, spacing: Space.s1 / 2) {
                Text(item.posterTitle)
                    .textRole(.headline)
                    .foregroundStyle(theme.ink)
                    .lineLimit(2)
                if let line = item.continueLine {
                    Text(line)
                        .textRole(.label)
                        .foregroundStyle(theme.ink2)
                        .monospacedDigit()
                }
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.spokenSummary)
    }
}

/// Fills in the shape of the Continue Watching row while Home loads.
private struct ContinueSkeleton: View {
    let cardWidth: CGFloat
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Capsule().fill(theme.trackOff).frame(width: 200, height: 20)
            HStack(spacing: Space.s3) {
                ForEach(0..<2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .fill(theme.trackOff)
                        .frame(width: cardWidth, height: (cardWidth * 9 / 16).rounded())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .padding(.leading, Space.inset)
        .accessibilityHidden(true)
    }
}

extension PlexMetadata {
    /// Wide art for a card: a show's backdrop for an episode, so a still never gives the plot away.
    var cardArtPath: String? {
        type == .episode ? (grandparentArt ?? art ?? thumb) : (art ?? thumb)
    }

    /// "S2 · E5 · 42 min left".
    fileprivate var continueLine: String? {
        let parts = [episodeCode, minutesLeft.map(ItemText.left)].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
