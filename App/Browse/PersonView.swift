import MarqueeCore
import SwiftUI

/// A cast or crew member's titles in the libraries, newest first: their photo, name and counts over a
/// poster grid.
struct PersonView: View {
    let id: String
    let name: String
    let thumb: String?

    @Environment(\.plexLibrary) private var library
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(LibraryChanges.self) private var changes
    @State private var titles: [PlexMetadata]?
    @State private var failed = false

    private static let photo: CGFloat = 96

    var body: some View {
        WidthReader { width in
            let metrics = PosterGridMetrics(width: width - Space.inset * 2, typeSize: typeSize)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s5) {
                    header
                    content(metrics)
                }
                .padding(.horizontal, Space.inset)
                .padding(.vertical, Space.s3)
            }
            .refreshable { await load() }
            .scrollHeader()
            .tabBarFollowsScroll()
        }
        .background(theme.canvas)
        .navigationTitle("Filmography")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: library?.instance) { await load() }
    }

    private var header: some View {
        HStack(spacing: Space.s4) {
            PlexArtView(path: thumb, size: CGSize(width: Self.photo, height: Self.photo), placeholder: "person.fill")
                .clipShape(Circle())
                .frame(width: Self.photo, height: Self.photo)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(name)
                    .textRole(.title)
                    .foregroundStyle(theme.ink)
                    .accessibilityAddTraits(.isHeader)
                if let counts {
                    Text(counts)
                        .textRole(.body)
                        .foregroundStyle(theme.ink2)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("person.header")
    }

    @ViewBuilder
    private func content(_ metrics: PosterGridMetrics) -> some View {
        if let titles {
            if titles.isEmpty {
                EmptyState(
                    title: "Nothing from this person is in your libraries",
                    message: "Titles with \(name) appear here once they are added to a library.",
                    systemImage: "person.crop.rectangle"
                )
            } else {
                LazyVGrid(columns: metrics.gridItems, alignment: .leading, spacing: Space.s4) {
                    ForEach(changes.shown(titles)) { item in
                        let zoomID = "person/\(item.ratingKey)"
                        NavigationLink(value: Route.to(item, zoomID: zoomID)) {
                            PosterCell(item: item, width: metrics.cellWidth, zoomID: zoomID)
                        }
                        .buttonStyle(.press)
                    }
                }
            }
        } else if failed {
            EmptyState(title: "Couldn't load", message: "The server didn't answer. Pull down to try again.", systemImage: "wifi.exclamationmark")
        } else {
            Skeleton.Grid(metrics: metrics)
        }
    }

    /// "3 films · 1 show".
    private var counts: String? {
        guard let titles, !titles.isEmpty else { return nil }
        let films = titles.count { $0.type == .movie }
        let shows = titles.count { $0.type == .show }
        let parts = [
            films > 0 ? (films == 1 ? "1 film" : "\(films) films") : nil,
            shows > 0 ? (shows == 1 ? "1 show" : "\(shows) shows") : nil,
        ]
        let text = parts.compactMap(\.self).joined(separator: " · ")
        return text.isEmpty ? nil : text
    }

    private func load() async {
        guard let library else { return }
        do {
            let found = try await library.titles(ofPerson: id)
            titles = found.sorted { ($0.originallyAvailableAt ?? "\($0.year ?? 0)") > ($1.originallyAvailableAt ?? "\($1.year ?? 0)") }
            failed = false
        } catch is CancellationError {
        } catch {
            failed = titles == nil
        }
    }
}
