import MarqueeCore
import SwiftUI

/// The profile's watchlist, as plex.tv keeps it: every saved title as a poster, whether or not this server
/// has it.
struct WatchlistView: View {
    @Environment(\.plexWatchlist) private var watchlist
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(LibraryChanges.self) private var changes
    @State private var titles = PagedLoader<PlexMetadata>()
    private let actions = ItemActions()
    private let prefetch = ArtPrefetcher()

    var body: some View {
        WidthReader { width in
            let metrics = PosterGridMetrics(width: width - Space.inset * 2, typeSize: typeSize)
            PagedContent(loader: titles) {
                ScrollView {
                    LazyVGrid(columns: metrics.gridItems, alignment: .leading, spacing: Space.s4) {
                        ForEach(titles.items) { item in
                            let zoomID = "watchlist/\(item.ratingKey)"
                            NavigationLink(value: Route.watchlist(item, zoomID: zoomID)) {
                                PosterCell(item: item, width: metrics.cellWidth, zoomID: zoomID)
                            }
                            .buttonStyle(.press)
                            .contextMenu {
                                if let guid = item.guid, actions.canWatchlist(guid) {
                                    Button("Remove from Watchlist", systemImage: "bookmark.slash", role: .destructive) {
                                        actions.setWatchlisted(false, guid: guid) { _ in }
                                    }
                                }
                            }
                            .onAppear { appeared(item, metrics: metrics) }
                        }
                    }
                    .padding(.horizontal, Space.inset)
                    .padding(.vertical, Space.s3)
                }
                .refreshable { await titles.refresh() }
            } skeleton: {
                ScrollView {
                    Skeleton.Grid(metrics: metrics)
                        .padding(.horizontal, Space.inset)
                        .padding(.top, Space.s3)
                }
                .scrollDisabled(true)
            } empty: {
                EmptyState(
                    title: "Nothing saved",
                    message: "Tap the bookmark on a title to save it here, from this iPhone or any Plex app.",
                    systemImage: "bookmark"
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.canvas)
        .navigationTitle("Watchlist")
        // Each profile has its own watchlist, reached with its own token.
        .task(id: watchlist.map { ObjectIdentifier($0.http) }) {
            guard let watchlist else { return }
            await titles.reload { start, size in
                try await watchlist.items(start: start, size: size)
            }
        }
        .onChange(of: changes.watchlistRevision) {
            Task { await titles.refresh() }
        }
    }

    private func appeared(_ item: PlexMetadata, metrics: PosterGridMetrics) {
        Task { await titles.loadMoreIfNeeded(after: item.id) }
        guard let index = titles.items.firstIndex(where: { $0.id == item.id }), index % metrics.columns == 0 else { return }
        let ahead = titles.items.dropFirst(index + metrics.columns * 2).prefix(metrics.columns * 2)
        prefetch(ahead.map(\.posterPath), size: PosterCell.artSize(width: metrics.cellWidth))
    }
}
