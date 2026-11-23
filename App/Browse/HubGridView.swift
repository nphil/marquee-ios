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
    @Environment(LibraryChanges.self) private var changes
    @State private var titles = PagedLoader<PlexMetadata>()

    var body: some View {
        WidthReader { width in
            let metrics = PosterGridMetrics(width: width - Space.inset * 2, typeSize: typeSize)
            PagedContent(loader: titles) {
                ScrollView {
                    LazyVGrid(columns: metrics.gridItems, alignment: .leading, spacing: Space.s4) {
                        ForEach(changes.shown(titles.items)) { item in
                            let zoomID = "all/\(item.ratingKey)"
                            NavigationLink(value: Route.to(item, zoomID: zoomID)) {
                                PosterCell(item: item, width: metrics.cellWidth, zoomID: zoomID)
                            }
                            .buttonStyle(.press)
                            .onAppear { titles.cellAppeared(item.id) }
                        }
                    }
                    .padding(.horizontal, Space.inset)
                    .padding(.vertical, Space.s3)
                    .prefetchesNewestPage(of: titles, cellWidth: metrics.cellWidth)
                }
                .refreshable { await titles.refresh() }
                .scrollHeader()
                .tabBarFollowsScroll()
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
}
