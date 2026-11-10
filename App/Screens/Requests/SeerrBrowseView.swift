import MarqueeCore
import SwiftUI

/// A Seerr Discover list as a poster grid that pages as it scrolls: a shelf's "See all" or a genre card.
/// Movies and series each list their genres as chips under a Movies | Series switch, and one View menu holds
/// the sorts and filters Seerr's discover endpoints take (DESIGN §8.8). Trending is only the grid.
struct SeerrBrowseView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let trending: Bool
    @State private var query: SeerrBrowseQuery
    @State private var pager = SeerrPager()
    @State private var attempt = 0
    /// The list the grid last loaded in full; see the task that loads it.
    @State private var loadedKey: ListKey?
    @State private var genres: [SeerrMediaKind: [SeerrGenre]] = [:]
    @State private var languages: [SeerrLanguage] = []
    @State private var regions: [SeerrRegion] = []
    @State private var providers: [ProviderList: [SeerrWatchProvider]] = [:]
    /// The region picked for the streaming filter; nil is the device's.
    @State private var region: String?

    init(feed: SeerrFeed) {
        switch feed {
        case .trending:
            trending = true
            _query = State(initialValue: SeerrBrowseQuery(kind: .movie))
        case .discover(let query):
            trending = false
            _query = State(initialValue: query)
        }
    }

    /// What the grid shows; a change loads it afresh.
    private struct ListKey: Hashable {
        let client: ObjectIdentifier?
        let feed: SeerrFeed
        let attempt: Int
    }

    private struct GenreKey: Hashable {
        let client: ObjectIdentifier?
        let kind: SeerrMediaKind
    }

    /// The streaming services TMDB lists for one kind in one region.
    private struct ProviderList: Hashable {
        let kind: SeerrMediaKind
        let region: String
    }

    private struct ProviderKey: Hashable {
        let client: ObjectIdentifier?
        let list: ProviderList?
    }

    private var feed: SeerrFeed {
        trending ? .trending : .discover(query)
    }

    private var title: String {
        if trending { return "Trending" }
        return query.kind == .movie ? "Movies" : "Series"
    }

    private var hasFilters: Bool {
        query.genre != nil || query.hasMenuFilters
    }

    var body: some View {
        let client = session.seerr.client
        let clientID = client.map(ObjectIdentifier.init)
        WidthReader { width in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    if !trending { header }
                    results(client: client, metrics: PosterGridMetrics(width: width - Space.inset * 2, typeSize: typeSize))
                }
                .padding(.top, Space.s2)
                .padding(.bottom, Space.s6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .refreshable { await pager.refresh() }
            .scrollHeader()
            .tabBarFollowsScroll()
        }
        .background(theme.canvas)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !trending {
                ToolbarItem(placement: .topBarTrailing) { viewMenu }
            }
        }
        .task(id: ListKey(client: clientID, feed: feed, attempt: attempt)) {
            guard let client else { return }
            let key = ListKey(client: clientID, feed: feed, attempt: attempt)
            // Coming back from a title page restarts this task; the list, and the place in it, stay.
            guard loadedKey != key else { return }
            await pager.reload { [feed = key.feed] page in try await client.browse(feed, page: page) }
            if pager.hasLoaded, !Task.isCancelled { loadedKey = key }
        }
        // What the chips and the menu list is extra: a failure leaves it out and the grid still loads.
        .task(id: GenreKey(client: clientID, kind: query.kind)) {
            let kind = query.kind
            guard !trending, let client, genres[kind] == nil else { return }
            guard let loaded = try? await client.genres(kind), !Task.isCancelled else { return }
            genres[kind] = loaded
        }
        .task(id: clientID) {
            guard !trending, let client else { return }
            async let languageList = try? await client.languages()
            async let regionList = try? await client.watchRegions()
            let (loadedLanguages, loadedRegions) = await (languageList, regionList)
            guard !Task.isCancelled else { return }
            languages = loadedLanguages ?? []
            regions = loadedRegions ?? []
        }
        .task(id: ProviderKey(client: clientID, list: regions.isEmpty ? nil : ProviderList(kind: query.kind, region: effectiveRegion))) {
            guard !trending, let client, regions.isEmpty == false else { return }
            let list = ProviderList(kind: query.kind, region: effectiveRegion)
            guard providers[list] == nil, let loaded = try? await client.watchProviders(list.kind, region: list.region), !Task.isCancelled else { return }
            providers[list] = loaded
        }
        // A request sent from a title page changes its badge here.
        .onChange(of: session.seerr.requestsSent) {
            Task { await pager.refreshLoaded() }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Picker("Show", selection: kind) {
                Text("Movies").tag(SeerrMediaKind.movie)
                Text("Series").tag(SeerrMediaKind.tv)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Space.inset)
            .accessibilityIdentifier("seerr.kind")
            if let list = genres[query.kind], !list.isEmpty {
                genreChips(list)
            }
            let filters = activeFilters
            if !filters.isEmpty {
                ChipFlow {
                    ForEach(filters) { filter in
                        FilterChip(title: filter.title, remove: filter.remove)
                    }
                }
                .padding(.horizontal, Space.inset)
            }
        }
    }

    /// Series and movies number their genres differently, so switching drops the genre.
    private var kind: Binding<SeerrMediaKind> {
        Binding {
            query.kind
        } set: { kind in
            guard kind != query.kind else { return }
            query.kind = kind
            query.genre = nil
        }
    }

    private func genreChips(_ list: [SeerrGenre]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: Space.s2) {
                    SelectChip(title: "All", isSelected: query.genre == nil) { choose(nil) }
                        .accessibilityIdentifier("seerr.chip.all")
                    ForEach(list) { genre in
                        SelectChip(title: genre.name, isSelected: query.genre == genre.id) { choose(genre.id) }
                            .id(genre.id)
                            .accessibilityIdentifier("seerr.chip.\(genre.id)")
                    }
                }
                .padding(.horizontal, Space.inset)
            }
            .scrollIndicators(.hidden)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Genres")
            .accessibilityIdentifier("seerr.genres")
            // A genre card opens with its chip chosen: bring the chip into view. A change of kind starts a
            // new strip at its first chip.
            .onAppear { reveal(query.genre, proxy, animated: false) }
            .onChange(of: query.genre) { _, genre in reveal(genre, proxy, animated: true) }
        }
        .id(query.kind)
    }

    private func choose(_ genre: Int?) {
        Haptics.selection()
        query.genre = genre
    }

    private func reveal(_ genre: Int?, _ proxy: ScrollViewProxy, animated: Bool) {
        guard let genre else { return }
        let animation = animated ? Motion.scroll(reduceMotion: reduceMotion) : nil
        Task {
            withAnimation(animation) { proxy.scrollTo(genre, anchor: .center) }
        }
    }

    // MARK: Active filters

    private struct ActiveFilter: Identifiable {
        let id: String
        let title: String
        let remove: @MainActor () -> Void
    }

    /// The View menu's filters that are on, each as a chip that turns it off. The genre has its own chips.
    private var activeFilters: [ActiveFilter] {
        var filters: [ActiveFilter] = []
        if query.upcoming {
            filters.append(ActiveFilter(id: "upcoming", title: "Upcoming") { query.upcoming = false })
        }
        if let era = query.era {
            filters.append(ActiveFilter(id: "era", title: era.title) { query.era = nil })
        }
        if let code = query.language {
            let name = languages.first { $0.code == code }?.name ?? code.uppercased()
            filters.append(ActiveFilter(id: "language", title: name) { query.language = nil })
        }
        if let rating = query.minRating {
            filters.append(ActiveFilter(id: "rating", title: "Rating \(rating)+") { query.minRating = nil })
        }
        if let runtime = query.runtime {
            filters.append(ActiveFilter(id: "runtime", title: runtime.title(for: query.kind)) { query.runtime = nil })
        }
        if let streaming = query.streaming {
            let list = providers[ProviderList(kind: query.kind, region: streaming.region)]
            let name = list?.first { $0.id == streaming.provider }?.name ?? "Streaming"
            filters.append(ActiveFilter(id: "streaming", title: "\(name) · \(streaming.region)") { query.streaming = nil })
        }
        return filters
    }

    // MARK: View menu

    private var viewMenu: some View {
        Menu {
            Section {
                ForEach(SeerrSort.allCases, id: \.self) { field in
                    MenuChoice(title: field.title, systemImage: field.systemImage, value: field, selection: sortField)
                }
            }
            Section {
                MenuChoice(title: query.sort.orders.first, systemImage: "arrow.down", value: false, selection: $query.reversed)
                MenuChoice(title: query.sort.orders.reversed, systemImage: "arrow.up", value: true, selection: $query.reversed)
            }
            Picker("Release", systemImage: "calendar", selection: $query.era) {
                Text("Any Year").tag(SeerrEra?.none)
                ForEach(SeerrEra.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
            }
            .pickerStyle(.menu)
            if !languages.isEmpty {
                Picker("Original Language", systemImage: "character.bubble", selection: $query.language) {
                    Text("Any Language").tag(String?.none)
                    ForEach(languages) { Text($0.name).tag(Optional($0.code)) }
                }
                .pickerStyle(.menu)
            }
            Picker("Rating", systemImage: "star", selection: $query.minRating) {
                Text("Any Rating").tag(Int?.none)
                ForEach([9, 8, 7, 6, 5], id: \.self) { Text("\($0)+").tag(Optional($0)) }
            }
            .pickerStyle(.menu)
            Picker("Runtime", systemImage: "clock", selection: $query.runtime) {
                Text("Any Length").tag(SeerrRuntime?.none)
                ForEach(SeerrRuntime.allCases, id: \.self) { Text($0.title(for: query.kind)).tag(Optional($0)) }
            }
            .pickerStyle(.menu)
            streamingPickers
            Toggle("Upcoming Only", systemImage: "calendar.badge.clock", isOn: $query.upcoming)
        } label: {
            Label("View", systemImage: "line.3.horizontal.decrease")
        }
        .accessibilityIdentifier("seerr.view")
    }

    @ViewBuilder private var streamingPickers: some View {
        let services = providers[ProviderList(kind: query.kind, region: effectiveRegion)] ?? []
        if !services.isEmpty {
            Picker("Streaming Service", systemImage: "tv", selection: service) {
                Text("Any Service").tag(Int?.none)
                ForEach(services) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.menu)
        }
        if !regions.isEmpty {
            Picker("Region", systemImage: "globe", selection: regionChoice) {
                ForEach(regions) { Text($0.name).tag($0.code) }
            }
            .pickerStyle(.menu)
        }
    }

    /// A new field starts in its first order: most popular, newest first, highest first, A–Z.
    private var sortField: Binding<SeerrSort> {
        Binding {
            query.sort
        } set: { field in
            query.sort = field
            query.reversed = false
        }
    }

    private var service: Binding<Int?> {
        Binding {
            query.streaming?.provider
        } set: { provider in
            query.streaming = provider.map { SeerrStreaming(provider: $0, region: effectiveRegion) }
        }
    }

    private var regionChoice: Binding<String> {
        Binding {
            effectiveRegion
        } set: { code in
            region = code
            if let current = query.streaming {
                query.streaming = SeerrStreaming(provider: current.provider, region: code)
            }
        }
    }

    /// Where the streaming services are looked up: the region of the filter, or the one picked, or the
    /// device's when TMDB lists it, else the US.
    private var effectiveRegion: String {
        if let chosen = query.streaming?.region ?? region { return chosen }
        if let device = Locale.current.region?.identifier, regions.isEmpty || regions.contains(where: { $0.code == device }) {
            return device
        }
        return "US"
    }

    // MARK: Results

    @ViewBuilder private func results(client: SeerrClient?, metrics: PosterGridMetrics) -> some View {
        if client == nil {
            EmptyState(title: "Set up Seerr", message: "Add Seerr in Settings under Integrations to discover and request movies and series.", systemImage: "plus.rectangle.on.folder")
        } else if !pager.items.isEmpty {
            grid(metrics: metrics)
        } else if let failure = pager.failure, !pager.isLoading {
            EmptyState(
                title: "Couldn't load Seerr",
                message: SeerrView.message(for: failure),
                systemImage: "exclamationmark.triangle",
                action: EmptyState.Action(title: "Try Again", systemImage: "arrow.clockwise") { attempt += 1 }
            )
        } else if pager.hasLoaded, !pager.isLoading {
            empty
        } else {
            Skeleton.Grid(metrics: metrics)
                .padding(.horizontal, Space.inset)
                .overlay { LoadingNote { attempt += 1 } }
        }
    }

    private func grid(metrics: PosterGridMetrics) -> some View {
        VStack(spacing: Space.s4) {
            LazyVGrid(columns: metrics.gridItems, alignment: .leading, spacing: Space.s4) {
                ForEach(pager.items) { title in
                    SeerrTitleButton(title: title, width: metrics.cellWidth)
                        .onAppear { Task { await pager.loadMoreIfNeeded(after: title.id) } }
                }
            }
            if pager.moreFailed {
                VStack(spacing: Space.s2) {
                    Text("Couldn't load more")
                        .textRole(.label)
                        .foregroundStyle(theme.ink2)
                    Button("Try Again") { Task { await pager.loadMore() } }
                        .buttonStyle(.pill)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, Space.inset)
    }

    @ViewBuilder private var empty: some View {
        if hasFilters {
            EmptyState(
                title: "No matches",
                message: "Nothing here fits these filters.",
                systemImage: "line.3.horizontal.decrease",
                action: EmptyState.Action(title: "Clear Filters", systemImage: "xmark") { clearFilters() }
            )
            .padding(.top, Space.s8)
        } else {
            EmptyState(title: "Nothing here", message: "Seerr lists no titles here.", systemImage: "film.stack")
                .padding(.top, Space.s8)
        }
    }

    /// Back to every title of the kind, keeping the sort.
    private func clearFilters() {
        query = SeerrBrowseQuery(kind: query.kind, sort: query.sort, reversed: query.reversed)
    }
}

extension SeerrSort {
    /// The glyph beside the name in the View menu, in the Library's family.
    var systemImage: String {
        switch self {
        case .popularity: "flame"
        case .release: "calendar"
        case .rating: "star"
        case .title: "textformat"
        }
    }
}
