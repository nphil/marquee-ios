import MarqueeCore
import SwiftUI

/// Every title behind a key the server handed out, as a poster grid: a shelf's "See all", a collection or
/// a person.
struct HubGridView: View {
    let key: String
    let title: String

    @Environment(\.plexLibrary) private var library
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var titles = PagedLoader<PlexMetadata>()
    private let prefetch = ArtPrefetcher()

    var body: some View {
        WidthReader { width in
            let metrics = PosterGridMetrics(width: width - Space.inset * 2, typeSize: typeSize)
            PagedContent(loader: titles) {
                ScrollView {
                    LazyVGrid(columns: metrics.gridItems, alignment: .leading, spacing: Space.s4) {
                        ForEach(titles.items) { item in
                            let zoomID = "all/\(item.ratingKey)"
                            NavigationLink(value: Route.to(item, zoomID: zoomID)) {
                                PosterCell(item: item, width: metrics.cellWidth, zoomID: zoomID)
                            }
                            .buttonStyle(.press)
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
                EmptyState(title: "Nothing here", message: "The server lists no titles here.", systemImage: "film.stack")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.canvas)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: library?.instance) {
            guard let library else { return }
            let key = key
            await titles.reload { start, size in
                try await library.list(key, start: start, size: size)
            }
        }
    }

    private func appeared(_ item: PlexMetadata, metrics: PosterGridMetrics) {
        Task { await titles.loadMoreIfNeeded(after: item.id) }
        guard let index = titles.items.firstIndex(where: { $0.id == item.id }), index % metrics.columns == 0 else { return }
        let ahead = titles.items.dropFirst(index + metrics.columns * 2).prefix(metrics.columns * 2)
        prefetch(ahead.map(\.posterPath), size: PosterCell.artSize(width: metrics.cellWidth))
    }
}
