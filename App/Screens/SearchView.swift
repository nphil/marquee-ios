import MarqueeCore
import SwiftUI

/// Search (DESIGN §8.5): the standard search tab, whose landing page keeps the field at the top. Results
/// arrive while typing, grouped into movies, shows, episodes and people, and the last four searches wait
/// under an empty field.
struct SearchView: View {
    @Environment(\.plexLibrary) private var library
    @Environment(\.theme) private var theme
    @Environment(\.openRoute) private var openRoute
    @Environment(\.sessionActions) private var session
    @State private var text = ""
    @State private var scope = SearchScope.all
    @State private var results = Remote<SearchResults>()
    @AppStorage("search.recents") private var storedRecents = ""

    private var query: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List {
            if query.isEmpty {
                recentSection
            } else if let shown = results.value {
                ForEach(groups(shown.hubs)) { group in
                    Section {
                        ForEach(group.rows) { row in
                            Button { open(row.route) } label: { ResultRow(row: row) }
                                .buttonStyle(.plain)
                                .listRowBackground(theme.canvas)
                                .listRowSeparatorTint(theme.edge)
                        }
                    } header: {
                        SectionTitle(title: group.title)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .environment(\.defaultMinListRowHeight, Size.rowMin)
        .background(theme.canvas)
        .overlay { state }
        .navigationTitle("Search")
        // Always shown: with the default placement iOS 27 tucks the field away as soon as the list
        // has rows, which left the landing page with no way to type.
        .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search your library")
        .searchScopes($scope, activation: .onSearchPresentation) {
            ForEach(SearchScope.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .onSubmit(of: .search) { remember(query) }
        .task(id: LoadKey(library: library?.instance, attempt: results.attempt, extra: query)) {
            guard let library, !query.isEmpty else { return }
            let query = query
            // Waits for a pause in typing; the next keystroke cancels the wait.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await results.load {
                SearchResults(query: query, hubs: try await library.search(query, limit: 10))
            }
        }
    }

    // MARK: States

    @ViewBuilder
    private var state: some View {
        if query.isEmpty {
            if recents.isEmpty {
                EmptyState(
                    title: "Search your library",
                    message: "Find movies, shows, episodes and people on \(serverName).",
                    systemImage: "magnifyingglass"
                )
            }
        } else if let shown = results.value {
            if shown.query == query, groups(shown.hubs).isEmpty {
                EmptyState(
                    title: "No results for “\(query)”",
                    message: scope == .all ? "Check the spelling or try another word." : "Try All, or another word.",
                    systemImage: "magnifyingglass"
                )
                .accessibilityIdentifier("search.noResults")
            }
        } else if let failure = results.failure, !results.isLoading {
            FailureState(failure: failure, server: serverName, retry: { results.retry() }, signIn: session.signInAgain)
        } else {
            Skeleton.Rows(artSize: ResultRow.art)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, Space.s3)
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        if !recents.isEmpty {
            Section {
                ForEach(recents, id: \.self) { recent in
                    Button {
                        text = recent
                    } label: {
                        Label(recent, systemImage: "clock.arrow.circlepath")
                            .textRole(.body)
                            .foregroundStyle(theme.ink, theme.ink2)
                            .frame(maxWidth: .infinity, minHeight: Size.target, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Remove", systemImage: "trash", role: .destructive) { forget(recent) }
                    }
                    .listRowBackground(theme.canvas)
                    .listRowSeparatorTint(theme.edge)
                }
            } header: {
                HStack {
                    SectionTitle(title: "Recent")
                    Spacer()
                    Button("Clear") { storedRecents = "" }
                        .textRole(.label)
                        .foregroundStyle(theme.accentText)
                        .frame(minHeight: Size.target)
                }
            }
        }
    }

    // MARK: Results

    private func groups(_ hubs: [PlexHub]) -> [ResultGroup] {
        let kinds = scope.kinds
        var groups: [ResultGroup] = []
        for (kind, title) in [("movie", "Movies"), ("show", "Shows"), ("episode", "Episodes")] where kinds.contains(kind) {
            let items = hubs.filter { $0.type == kind }.flatMap(\.items)
            guard !items.isEmpty else { continue }
            groups.append(ResultGroup(title: title, rows: items.map { ResultRow.Model(item: $0) }))
        }
        if scope == .all {
            var seen = Set<String>()
            let people = hubs.filter { $0.type == "actor" || $0.type == "director" }.flatMap { hub in
                hub.directories.map { (person: $0, role: hub.type == "director" ? "Director" : "Actor") }
            }
            let rows = people.filter { seen.insert($0.person.key).inserted }.map { ResultRow.Model(person: $0.person, role: $0.role) }
            if !rows.isEmpty {
                groups.append(ResultGroup(title: "People", rows: rows))
            }
        }
        return groups
    }

    private func open(_ route: Route) {
        remember(query)
        openRoute(route)
    }

    // MARK: Recents

    private var recents: [String] {
        storedRecents.split(separator: "\n").map(String.init)
    }

    private func remember(_ query: String) {
        guard !query.isEmpty else { return }
        let others = recents.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        storedRecents = ([query] + others).prefix(4).joined(separator: "\n")
    }

    private func forget(_ recent: String) {
        storedRecents = recents.filter { $0 != recent }.joined(separator: "\n")
    }

    private var serverName: String {
        library?.server.name ?? "the server"
    }
}

/// The results of one search, kept with the words that found them.
struct SearchResults: Sendable {
    let query: String
    let hubs: [PlexHub]
}

private enum SearchScope: CaseIterable, Hashable {
    case all, movies, shows, episodes

    var title: String {
        switch self {
        case .all: "All"
        case .movies: "Movies"
        case .shows: "Shows"
        case .episodes: "Episodes"
        }
    }

    /// The hub types the scope shows.
    var kinds: Set<String> {
        switch self {
        case .all: ["movie", "show", "episode"]
        case .movies: ["movie"]
        case .shows: ["show"]
        case .episodes: ["episode"]
        }
    }
}

private struct ResultGroup: Identifiable {
    let title: String
    let rows: [ResultRow.Model]
    var id: String { title }
}

private struct SectionTitle: View {
    let title: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(title)
            .textRole(.headline)
            .foregroundStyle(theme.ink)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A title with its poster at 56 × 84, or a person with their photo in a circle.
private struct ResultRow: View {
    let row: Model

    @Environment(\.theme) private var theme
    static let art = CGSize(width: 56, height: 84)

    struct Model: Identifiable {
        let id: String
        let title: String
        let detail: String
        let art: String?
        let isPerson: Bool
        let route: Route

        init(item: PlexMetadata) {
            id = item.ratingKey
            title = item.title
            detail = item.kindLine
            art = item.posterPath
            isPerson = false
            route = Route.to(item, zoomID: "search/\(item.ratingKey)")
        }

        init(person: PlexDirectory, role: String) {
            let name = person.tag ?? person.title
            id = "person/\(person.key)"
            title = name
            detail = role
            art = person.thumb
            isPerson = true
            route = person.id.map { .person(id: $0, name: name, thumb: person.thumb) } ?? .hub(key: person.key, title: name)
        }
    }

    var body: some View {
        HStack(spacing: Space.s3) {
            if row.isPerson {
                PlexArtView(path: row.art, size: CGSize(width: Self.art.width, height: Self.art.width), placeholder: "person.fill")
                    .clipShape(Circle())
                    .frame(width: Self.art.width, height: Self.art.height)
            } else {
                PlexArtView(path: row.art, size: Self.art)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .zoomSource(row.route.zoomID, cornerRadius: Radius.control)
            }
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(row.title)
                    .textRole(.headline)
                    .foregroundStyle(theme.ink)
                    .lineLimit(2)
                Text(row.detail)
                    .textRole(.label)
                    .foregroundStyle(theme.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Space.s1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("search.result.\(row.id)")
    }
}
