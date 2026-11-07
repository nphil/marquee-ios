import MarqueeCore
import SwiftUI

/// Library (DESIGN §8.2): one movie or TV library at a time, picked from the title menu, shown as a poster
/// grid with a View menu, filter chips and an A–Z rail, or as its collections or the server's picks.
struct LibraryView: View {
    @Environment(\.plexLibrary) private var library
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(AppSession.self) private var session
    @State private var sections = Remote<[PlexLibrarySection]>()
    @AppStorage("library.section") private var chosenKey = ""

    var body: some View {
        WidthReader { width in
            RemoteContent(remote: sections) { sections in
                let movieAndTV = sections.filter { $0.type == .movie || $0.type == .show }
                let favorites = movieAndTV.filter { !session.settings.hiddenLibraries.contains(HomeLayout.libraryID($0)) }
                let browsable = favorites.isEmpty ? movieAndTV : favorites
                if let section = browsable.first(where: { $0.key == chosenKey }) ?? browsable.first {
                    SectionBrowser(section: section, width: width)
                        .id(section.key)
                        .toolbarTitleMenu {
                            Picker("Library", selection: Binding(get: { section.key }, set: { chosenKey = $0 })) {
                                ForEach(browsable) { Text($0.title).tag($0.key) }
                            }
                        }
                } else {
                    EmptyState(
                        title: "No libraries",
                        message: "This server shares no movie or TV libraries.",
                        systemImage: "film.stack",
                        action: EmptyState.Action(title: "Refresh", systemImage: "arrow.clockwise") { self.sections.retry() }
                    )
                    .navigationTitle("Library")
                }
            } skeleton: {
                ScrollView {
                    Skeleton.Grid(metrics: PosterGridMetrics(width: width - Space.inset * 2, typeSize: typeSize))
                        .padding(.horizontal, Space.inset)
                        .padding(.top, Space.s3)
                }
                .scrollDisabled(true)
                .navigationTitle("Library")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.canvas)
        .task(id: LoadKey(library: library?.instance, attempt: sections.attempt)) {
            guard let library else { return }
            await sections.load { try await library.sections() }
        }
    }
}

/// One library: its titles, its collections, or what the server recommends from it.
private struct SectionBrowser: View {
    let section: PlexLibrarySection
    let width: CGFloat

    @Environment(\.plexLibrary) private var library
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(LibraryChanges.self) private var changes
    @State private var segment = Segment.all
    @State private var sort = SectionQuery.Sort.title
    @State private var reversed = false
    @State private var unwatchedOnly = false
    @State private var genre: PlexDirectory? = nil
    @State private var titles = PagedLoader<PlexMetadata>()
    @State private var collections = PagedLoader<PlexMetadata>()
    @State private var recommended = Remote<[PlexHub]>()
    @State private var letters = Remote<[AlphabetIndexEntry]>()
    @State private var genres = Remote<[PlexDirectory]>()
    @State private var jumpTask: Task<Void, Never>? = nil
    private let prefetch = ArtPrefetcher()

    enum Segment: Hashable {
        case all, collections, recommended
    }

    /// What the titles grid shows; a change reloads it.
    private struct GridKey: Hashable {
        let library: ObjectIdentifier?
        let query: SectionQuery
    }

    private var query: SectionQuery {
        SectionQuery(type: section.type, sort: sort, reversed: reversed, unwatchedOnly: unwatchedOnly, genre: genre)
    }

    private var showsRail: Bool {
        segment == .all && query.isAlphabetical && (letters.value?.count ?? 0) > 1 && !titles.items.isEmpty
    }

    private var metrics: PosterGridMetrics {
        PosterGridMetrics(width: width - Space.inset - trailingInset, typeSize: typeSize)
    }

    /// The rail sits in a wider trailing inset, so it never covers a poster.
    private var trailingInset: CGFloat {
        showsRail ? Space.s7 : Space.inset
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    header
                    switch segment {
                    case .all: titlesGrid
                    case .collections: collectionsGrid
                    case .recommended: recommendedShelves
                    }
                }
                .padding(.top, Space.s2)
                .padding(.bottom, Space.s6)
            }
            .refreshable { await refresh() }
            .safeAreaInset(edge: .top, spacing: 0) { banner }
            .overlay(alignment: .trailing) {
                if showsRail, let entries = letters.value {
                    AlphabetRail(entries: entries) { jump(to: $0, proxy) }
                        .padding(.vertical, Space.s4)
                }
            }
            .toolbar {
                if showsRail, let entries = letters.value {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            ForEach(entries, id: \.character) { entry in
                                Button(entry.character) { jump(to: entry, proxy) }
                            }
                        } label: {
                            Label("Jump To", systemImage: "textformat.abc")
                        }
                    }
                }
                if segment == .all {
                    ToolbarItem(placement: .topBarTrailing) { viewMenu }
                }
            }
        }
        .navigationTitle(section.title)
        .task(id: GridKey(library: library?.instance, query: query)) {
            guard let library else { return }
            let key = section.key
            let query = query
            await titles.reload { start, size in
                try await library.items(in: key, query: query, start: start, size: size)
            }
        }
        .task(id: query.isAlphabetical ? GridKey(library: library?.instance, query: query) : nil) {
            guard let library, query.isAlphabetical else { return }
            await loadLetters(library)
        }
        .task(id: segment == .collections ? library?.instance : nil) {
            guard let library, segment == .collections else { return }
            let key = section.key
            await collections.reload { start, size in
                try await library.collections(in: key, start: start, size: size)
            }
        }
        .task(id: segment == .recommended ? LoadKey(library: library?.instance, attempt: recommended.attempt) : nil) {
            guard let library, segment == .recommended else { return }
            await loadRecommended(library)
        }
        .task(id: library?.instance) {
            guard let library else { return }
            let key = section.key
            await genres.load { try await library.genres(in: key) }
        }
        .onChange(of: changes.revision) { old, _ in
            refreshTouched(after: old)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Picker("Show", selection: $segment) {
                Text("All").tag(Segment.all)
                Text("Collections").tag(Segment.collections)
                Text("Recommended").tag(Segment.recommended)
            }
            .pickerStyle(.segmented)
            if segment == .all, unwatchedOnly || genre != nil {
                ChipFlow {
                    if unwatchedOnly {
                        FilterChip(title: "Unwatched") { unwatchedOnly = false }
                    }
                    if let genre {
                        FilterChip(title: genre.title) { self.genre = nil }
                    }
                }
            }
        }
        .padding(.horizontal, Space.inset)
    }

    private var viewMenu: some View {
        Menu {
            Picker("Sort By", selection: sortField) {
                ForEach(SectionQuery.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            if let orders = sort.orders {
                Picker("Order", selection: $reversed) {
                    Text(orders.first).tag(false)
                    Text(orders.reversed).tag(true)
                }
                .pickerStyle(.inline)
            }
            if let genres = genres.value, !genres.isEmpty {
                Picker("Genre", systemImage: "theatermasks", selection: $genre) {
                    Text("All Genres").tag(PlexDirectory?.none)
                    ForEach(genres, id: \.key) { Text($0.title).tag(Optional($0)) }
                }
                .pickerStyle(.menu)
            }
            Toggle("Unwatched Only", systemImage: "eye.slash", isOn: $unwatchedOnly)
        } label: {
            Label("View", systemImage: "line.3.horizontal.decrease")
        }
    }

    /// A new field starts in its first order: A–Z, newest first, highest first.
    private var sortField: Binding<SectionQuery.Sort> {
        Binding {
            sort
        } set: { field in
            sort = field
            reversed = false
        }
    }

    // MARK: Segments

    private var titlesGrid: some View {
        PagedContent(loader: titles, banner: false) {
            grid(titles, zoomPrefix: "grid")
                .environment(\.posterSort, sort)
        } skeleton: {
            skeleton
        } empty: {
            if unwatchedOnly || genre != nil {
                EmptyState(
                    title: "No matches",
                    message: "Nothing in \(section.title) fits these filters.",
                    systemImage: "line.3.horizontal.decrease",
                    action: EmptyState.Action(title: "Clear Filters", systemImage: "xmark") {
                        unwatchedOnly = false
                        genre = nil
                    }
                )
                .padding(.top, Space.s8)
            } else {
                EmptyState(
                    title: section.type == .show ? "No shows yet" : "No movies yet",
                    message: "Add some on the server.",
                    systemImage: "film.stack",
                    action: EmptyState.Action(title: "Refresh", systemImage: "arrow.clockwise") {
                        Task { await titles.refresh() }
                    }
                )
                .padding(.top, Space.s8)
            }
        }
    }

    private var collectionsGrid: some View {
        PagedContent(loader: collections, banner: false) {
            grid(collections, zoomPrefix: "collections")
        } skeleton: {
            skeleton
        } empty: {
            EmptyState(title: "No collections", message: "\(section.title) has no collections yet.", systemImage: "square.stack")
                .padding(.top, Space.s8)
        }
    }

    private var recommendedShelves: some View {
        RemoteContent(remote: recommended) { hubs in
            let shelves = hubs.filter { !$0.items.isEmpty }
            if shelves.isEmpty {
                EmptyState(title: "Nothing to suggest", message: "The server has no picks from \(section.title) yet.", systemImage: "sparkles")
                    .padding(.top, Space.s8)
            } else {
                LazyVStack(alignment: .leading, spacing: Space.s7) {
                    ForEach(shelves) { PosterShelf(hub: $0) }
                }
            }
        } skeleton: {
            VStack(alignment: .leading, spacing: Space.s7) {
                Skeleton.Shelf()
                Skeleton.Shelf()
            }
        }
    }

    private var skeleton: some View {
        Skeleton.Grid(metrics: metrics)
            .padding(.leading, Space.inset)
    }

    private func grid(_ loader: PagedLoader<PlexMetadata>, zoomPrefix: String) -> some View {
        let metrics = metrics
        return LazyVGrid(columns: metrics.gridItems, alignment: .leading, spacing: Space.s4) {
            ForEach(changes.shown(loader.items)) { item in
                let zoomID = "\(zoomPrefix)/\(item.ratingKey)"
                NavigationLink(value: Route.to(item, zoomID: zoomID)) {
                    PosterCell(item: item, width: metrics.cellWidth, zoomID: zoomID)
                }
                .buttonStyle(.press)
                .id(item.id)
                .onAppear { appeared(item, in: loader, metrics: metrics) }
            }
        }
        .padding(.leading, Space.inset)
        .padding(.trailing, trailingInset)
    }

    @ViewBuilder
    private var banner: some View {
        let loader = segment == .collections ? collections : titles
        if segment != .recommended, !loader.items.isEmpty, let failure = loader.failure, let loadedAt = loader.loadedAt,
           (failure as? PlexError) != .unauthorized {
            OfflineBanner(server: library?.server.name ?? "the server", since: loadedAt, isRetrying: loader.isLoading) {
                Task { await loader.refresh() }
            }
        }
    }

    // MARK: Loading

    /// Asks for the next page near the end, and starts the posters two to four rows ahead.
    private func appeared(_ item: PlexMetadata, in loader: PagedLoader<PlexMetadata>, metrics: PosterGridMetrics) {
        Task { await loader.loadMoreIfNeeded(after: item.id) }
        guard let index = loader.items.firstIndex(where: { $0.id == item.id }), index % metrics.columns == 0 else { return }
        let ahead = loader.items.dropFirst(index + metrics.columns * 2).prefix(metrics.columns * 2)
        prefetch(ahead.map(\.posterPath), size: PosterCell.artSize(width: metrics.cellWidth))
    }

    private func loadLetters(_ library: PlexLibrary) async {
        let key = section.key
        let query = query
        await letters.load { try await library.alphabetIndex(in: key, query: query) }
    }

    private func loadRecommended(_ library: PlexLibrary) async {
        let key = section.key
        await recommended.load { try await library.recommendedHubs(in: key) }
    }

    private func refresh() async {
        guard let library else { return }
        switch segment {
        case .all:
            await titles.refresh()
            if query.isAlphabetical { await loadLetters(library) }
        case .collections:
            await collections.refresh()
        case .recommended:
            await loadRecommended(library)
        }
    }

    /// Fetches again the shown titles that a watched change touched, in place.
    private func refreshTouched(after revision: Int) {
        guard let library else { return }
        let touched = changes.keys(after: revision)
        let stale = changes.shown(titles.items).map(\.ratingKey).filter(touched.contains)
        guard !stale.isEmpty else { return }
        let titles = titles
        Task {
            for key in stale {
                if let fresh = try? await library.metadata(key) {
                    _ = titles.patch(fresh)
                }
            }
        }
    }

    /// Loads as far as the letter, then scrolls its first title to the top (DESIGN §8.2).
    private func jump(to entry: AlphabetIndexEntry, _ proxy: ScrollViewProxy) {
        jumpTask?.cancel()
        let titles = titles
        let animation = Motion.scroll(reduceMotion: reduceMotion)
        jumpTask = Task {
            await titles.ensureLoaded(through: entry.offset)
            guard !Task.isCancelled, entry.offset < titles.items.count else { return }
            let id = titles.items[entry.offset].id
            withAnimation(animation) {
                proxy.scrollTo(id, anchor: .top)
            }
        }
    }
}

/// The A–Z rail (DESIGN §8.2): letters in Caption down the trailing edge. Dragging along it jumps letter by
/// letter with a selection tick; the "Jump To" menu is the same jump for VoiceOver and Switch Control.
private struct AlphabetRail: View {
    let entries: [AlphabetIndexEntry]
    let select: @MainActor (AlphabetIndexEntry) -> Void

    @Environment(\.theme) private var theme
    @State private var current: String? = nil
    @State private var height: CGFloat = 0

    private static let rowHeight: CGFloat = 16
    private static let width: CGFloat = 24

    var body: some View {
        let shown = shownEntries
        VStack(spacing: 0) {
            ForEach(shown, id: \.character) { entry in
                Text(entry.character)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(entry.character == current ? theme.accentText : theme.ink2)
                    .frame(width: Self.width, height: Self.rowHeight)
            }
        }
        .frame(maxHeight: .infinity)
        .frame(width: Size.target / 2 + Space.s2)
        .contentShape(Rectangle())
        // An unbounded measuring pass reports an infinite height, which no letter count can be made from.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if $0.isFinite { height = $0 } }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { pick(at: $0.location.y, shownCount: shown.count) }
                .onEnded { _ in current = nil }
        )
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityHidden(true)
    }

    /// Every letter when they fit; otherwise an even sample, with the drag still reaching every letter.
    private var shownEntries: [AlphabetIndexEntry] {
        let fitting = max(Int(height / Self.rowHeight), 2)
        guard entries.count > fitting else { return entries }
        let step = Double(entries.count - 1) / Double(fitting - 1)
        return (0..<fitting).map { entries[Int((Double($0) * step).rounded())] }
    }

    private func pick(at y: CGFloat, shownCount: Int) {
        let band = CGFloat(shownCount) * Self.rowHeight
        let top = (height - band) / 2
        let fraction = min(max((y - top) / max(band, 1), 0), 0.999)
        let entry = entries[Int(fraction * CGFloat(entries.count))]
        guard entry.character != current else { return }
        current = entry.character
        Haptics.selection()
        select(entry)
    }
}
