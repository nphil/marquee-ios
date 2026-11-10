import MarqueeCore
import SwiftUI

/// The Discover page's rows in Seerr's order. Each row asks for its titles when it nears the screen, shows
/// a skeleton until they arrive, and leaves no gap when it fails or has nothing.
struct DiscoverRows: View {
    let feed: DiscoverFeed
    let client: SeerrClient

    /// What a row's loading task restarts on: another Seerr, or `DiscoverFeed.generation` after a reload.
    private struct LoadID: Hashable {
        let client: ObjectIdentifier
        let generation: Int
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(SeerrDiscoverRow.all) { row in
                rowView(row)
                    .task(id: LoadID(client: ObjectIdentifier(client), generation: feed.generation)) {
                        feed.load(row, using: client)
                    }
            }
        }
    }

    private func rowView(_ row: SeerrDiscoverRow) -> some View {
        let content = feed.content[row]
        return VStack(alignment: .leading, spacing: 0) {
            if let content {
                switch (row, content) {
                case (.shelf(let shelf), .titles(let titles)):
                    TitleShelf(shelf: shelf, titles: titles)
                case (.genres(let kind), .genres(let genres)):
                    GenreShelf(title: row.title, kind: kind, genres: genres)
                default:
                    EmptyView()
                }
            } else if !feed.settled.contains(row) {
                switch row {
                case .shelf: Skeleton.Shelf()
                case .genres: GenreSkeleton()
                }
            }
        }
        .padding(.bottom, content == nil && feed.settled.contains(row) ? 0 : Space.s7)
    }
}

/// Posters under a header whose chevron opens the whole list; the same shelf as Home's.
private struct TitleShelf: View {
    let shelf: SeerrShelf
    let titles: [SeerrTitle]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            ShelfHeader(title: shelf.title, seeAll: .seerrBrowse(shelf.feed))
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Space.s3) {
                    ForEach(titles) { title in
                        SeerrTitleButton(title: title, width: Size.gridMin)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, Space.inset, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

/// One card per genre of movies or series; the header's chevron opens the unfiltered list.
private struct GenreShelf: View {
    let title: String
    let kind: SeerrMediaKind
    let genres: [SeerrGenre]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            ShelfHeader(title: title, seeAll: .seerrBrowse(.discover(SeerrBrowseQuery(kind: kind))))
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Space.s3) {
                    ForEach(genres) { genre in
                        GenreCard(kind: kind, genre: genre)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, Space.inset, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

/// A genre's backdrop with its name under it; opens that genre's list.
private struct GenreCard: View {
    let kind: SeerrMediaKind
    let genre: SeerrGenre

    @Environment(\.openRoute) private var openRoute
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var scale

    /// 16:9, as TMDB's backdrops are.
    static let artSize = CGSize(width: 168, height: 95)

    var body: some View {
        Button {
            openRoute(.seerrBrowse(.discover(SeerrBrowseQuery(kind: kind, genre: genre.id))))
        } label: {
            VStack(alignment: .leading, spacing: Space.s1) {
                PlexArtView(path: TMDBImage.url(genre.backdropPath, pixels: Self.artSize.width * scale)?.absoluteString, size: Self.artSize)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                Text(genre.name)
                    .textRole(.caption).fontWeight(.semibold)
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
            }
            .frame(width: Self.artSize.width, alignment: .leading)
        }
        .buttonStyle(.press)
        .accessibilityIdentifier("seerr.genre.\(kind.rawValue).\(genre.id)")
    }
}

/// `Skeleton.Shelf` for a row of genre cards.
private struct GenreSkeleton: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Capsule().fill(theme.trackOff).frame(width: 160, height: 20)
                .padding(.horizontal, Space.inset)
            HStack(alignment: .top, spacing: Space.s3) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                        .fill(theme.trackOff)
                        .frame(width: GenreCard.artSize.width, height: GenreCard.artSize.height)
                }
            }
            .padding(.leading, Space.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .accessibilityHidden(true)
    }
}
