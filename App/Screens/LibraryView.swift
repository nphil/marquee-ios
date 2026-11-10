import MarqueeCore
import SwiftUI

/// Library (DESIGN §8.2): one movie or TV library at a time, picked from the title menu, shown as a poster
/// grid with a View menu, filter chips and an A–Z rail, or as its collections or the server's picks. The
/// title menu and the header also open the places that are not tabs (§7).
struct LibraryView: View {
    @Environment(\.plexLibrary) private var library
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(AppSession.self) private var session
    @Environment(\.tabSelection) private var tabs
    @Environment(\.openDestination) private var openDestination
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
                        .titleMenu(section.title) {
                            Section {
                                ForEach(browsable) { library in
                                    MenuChoice(
                                        title: library.title,
                                        systemImage: library.type.libraryImage,
                                        value: library.key,
                                        selection: Binding(get: { section.key }, set: { chosenKey = $0 })
                                    )
                                }
                            }
                            // Search and Requests have their own buttons in the header.
                            let places = [Destination.liveTV, .watchlist, .downloads].filter {
                                !tabs.isTab($0) && $0.isAvailable(in: session)
                            }
                            if !places.isEmpty {
                                Section {
                                    ForEach(places) { place in
                                        Button(place.title, systemImage: place.systemImage) { openDestination(place) }
                                    }
                                }
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
        .toolbarTitleDisplayMode(.inlineLarge)
        .task(id: LoadKey(library: library?.instance, attempt: sections.attempt)) {
            guard let library else { return }
            await sections.load { try await library.sections() }
        }
    }
}

extension PlexMediaType {
    /// The glyph for a library of this type in the title menu.
    var libraryImage: String {
        switch self {
        case .movie, .clip: "film"
        case .show, .season, .episode: "tv"
        case .collection: "square.stack"
        case .playlist: "music.note.list"
        case .unknown: "folder"
        }
    }
}

extension SectionQuery.Sort {
    /// The glyph beside the name in the View menu.
    var systemImage: String {
        switch self {
        case .title: "textformat"
        case .recentlyAdded: "calendar.badge.plus"
        case .releaseDate: "calendar"
        case .rating: "star"
        case .audienceRating: "person.2"
        case .recentlyWatched: "clock"
        case .plays: "play.circle"
        case .random: "shuffle"
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
    @Environment(AppSession.self) private var session
    @Environment(\.tabSelection) private var tabs
    @Environment(\.openDestination) private var openDestination
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
            .scrollHeader()
            .tabBarFollowsScroll()
            .safeAreaInset(edge: .top, spacing: 0) { banner }
            .overlay(alignment: .trailing) {
                if showsRail, let entries = letters.value {
                    AlphabetRail(entries: entries) { jump(to: $0, proxy) }
                        .padding(.vertical, Space.s4)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !tabs.isTab(.search) {
                        Button("Search", systemImage: Destination.search.systemImage) { openDestination(.search) }
                            .accessibilityIdentifier("library.search")
                    }
                    if segment == .all { viewMenu }
                }
                if !tabs.isTab(.requests), Destination.requests.isAvailable(in: session) {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Requests", systemImage: "plus") { openDestination(.requests) }
                            .accessibilityIdentifier("library.requests")
                    }
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
            Section {
                ForEach(SectionQuery.Sort.allCases, id: \.self) { field in
                    MenuChoice(title: field.title, systemImage: field.systemImage, value: field, selection: sortField)
                }
            }
            if let orders = sort.orders {
                // Both read downward from the first item: A to Z, newest to oldest, highest to lowest.
                Section {
                    MenuChoice(title: orders.first, systemImage: "arrow.down", value: false, selection: $reversed)
                    MenuChoice(title: orders.reversed, systemImage: "arrow.up", value: true, selection: $reversed)
                }
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
                .showWatchedMenu(item) { shown in _ = loader.patch(item.markedWatched(shown)) }
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

/// The A–Z rail (DESIGN §8.2): letters in Caption down the trailing edge. Touching it jumps letter by letter
/// with a selection tick, while the letters around the finger swell and lean out over a lens and the touched
/// letter shows large in a callout beside it. VoiceOver and Switch Control step it a letter at a time.
private struct AlphabetRail: View {
    let entries: [AlphabetIndexEntry]
    let select: @MainActor (AlphabetIndexEntry) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var current: String? = nil
    /// The finger's height on the rail while it touches it.
    @State private var finger: CGFloat? = nil
    @State private var height: CGFloat = 0
    /// Where VoiceOver and Switch Control last stepped to, an index into `entries`.
    @State private var stepped = 0
    /// The letter in the callout. Kept after the finger lifts, so the callout fades out still showing it.
    @State private var callout = ""

    private static let rowHeight: CGFloat = 16
    private static let width: CGFloat = 24
    /// Room for the touched letter leaning 46 pt out and for two letters either side of it.
    private static let lens = CGSize(width: Size.target * 2, height: Size.target * 2)
    private static let follow = Animation.interactiveSpring(response: 0.15, dampingFraction: 0.86)

    var body: some View {
        let shown = shownEntries
        let top = (height - CGFloat(shown.count) * Self.rowHeight) / 2
        // The finger as a fractional row of the shown letters, 0 at the first one's centre.
        let focus = finger.map { ($0 - top) / Self.rowHeight - 0.5 }
        // Caption 2, capped as the rail is. Set at the lens's peak size and scaled down, since text scaled
        // up is a stretched bitmap and the touched letter came out soft.
        let glyph = Manrope.size(11, as: .caption2, at: typeSize, cap: .xxxLarge)
        let letter = glyph * LetterLens.peak
        let calloutGlyph = Manrope.size(44, as: .largeTitle, at: typeSize, cap: .xxxLarge)
        let calloutSide = (calloutGlyph * 1.8).rounded()
        // Tall enough for the touched letter and two either side, which spread apart as they swell.
        let lensHeight = max(Self.lens.height, 2 * (LetterLens.position(2, row: Self.rowHeight, glyph: glyph)
            + LetterLens.height(of: 2, glyph: glyph) / 2 + Space.s1))
        VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.character) { row, entry in
                let lens = LetterLens(
                    offset: focus.map { CGFloat(row) - $0 }, reduceMotion: reduceMotion, row: Self.rowHeight, glyph: glyph
                )
                Text(entry.character)
                    .font(.system(size: letter, weight: .semibold))
                    .fixedSize()
                    .foregroundStyle(entry.character == current ? theme.accentText : focus == nil ? theme.ink2 : theme.ink)
                    .frame(width: Self.width, height: Self.rowHeight)
                    .scaleEffect(lens.scale / LetterLens.peak)
                    .offset(x: -lens.lean, y: lens.shift)
                    .opacity(lens.opacity)
            }
        }
        .frame(maxHeight: .infinity)
        .frame(width: Size.target / 2 + Space.s2)
        .background(alignment: .topTrailing) {
            if let focus {
                let shape = RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                shape
                    .fill(panel)
                    .overlay { shape.strokeBorder(theme.edge, lineWidth: 1) }
                    .frame(width: Self.lens.width, height: lensHeight)
                    .offset(y: top + (focus + 0.5) * Self.rowHeight - lensHeight / 2)
                    .transition(.opacity)
            }
        }
        // Solid like the lens: glass over the scrolling grid would resample it every frame.
        .background(alignment: .topTrailing) {
            if let finger, !callout.isEmpty {
                let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                Text(callout)
                    .font(.custom(Manrope.bold.rawValue, fixedSize: calloutGlyph))
                    .foregroundStyle(theme.accentText)
                    .frame(width: calloutSide, height: calloutSide)
                    .background(panel, in: shape)
                    .overlay { shape.strokeBorder(theme.edge, lineWidth: 1) }
                    .offset(
                        x: -(Self.lens.width + Space.s3),
                        y: min(max(finger - calloutSide / 2, 0), max(height - calloutSide, 0))
                    )
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        // An unbounded measuring pass reports an infinite height, which no letter count can be made from.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if $0.isFinite { height = $0 } }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    withAnimation(reduceMotion ? nil : Self.follow) { finger = drag.location.y }
                    pick(at: drag.location.y, shownCount: shown.count)
                }
                .onEnded { _ in
                    withAnimation(reduceMotion ? nil : Self.follow) { finger = nil }
                    current = nil
                }
        )
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement()
        .accessibilityLabel("Alphabet")
        .accessibilityValue(entries[min(stepped, entries.count - 1)].character)
        .accessibilityHint("Swipe up or down to jump to a letter.")
        .accessibilityAdjustableAction { direction in
            let now = min(stepped, entries.count - 1)
            switch direction {
            case .increment: stepped = min(now + 1, entries.count - 1)
            case .decrement: stepped = max(now - 1, 0)
            @unknown default: return
            }
            select(entries[stepped])
        }
        .accessibilityIdentifier("library.alphabetRail")
        #if DEBUG
        .task(id: height) { holdForTest() }
        #endif
    }

    /// Every letter when they fit; otherwise an even sample, with the drag still reaching every letter.
    private var shownEntries: [AlphabetIndexEntry] {
        let fitting = max(Int(height / Self.rowHeight), 2)
        guard entries.count > fitting else { return entries }
        let step = Double(entries.count - 1) / Double(fitting - 1)
        return (0..<fitting).map { entries[Int((Double($0) * step).rounded())] }
    }

    private var panel: Color {
        theme.roles.sheet.over(theme.roles.canvas).color
    }

    private func pick(at y: CGFloat, shownCount: Int) {
        let band = CGFloat(shownCount) * Self.rowHeight
        let top = (height - band) / 2
        let fraction = min(max((y - top) / max(band, 1), 0), 0.999)
        let entry = entries[Int(fraction * CGFloat(entries.count))]
        guard entry.character != current else { return }
        current = entry.character
        callout = entry.character
        Haptics.selection()
        select(entry)
    }

    #if DEBUG
    /// UI tests hold the rail mid-scrub on a letter (`-marquee.uitest.railScrub`), since a touch cannot be
    /// held while the test takes its screenshot.
    private func holdForTest() {
        let shown = shownEntries
        guard FakePlex.isActive, height > 0, finger == nil,
              let letter = UserDefaults.standard.string(forKey: "marquee.uitest.railScrub"),
              let row = shown.firstIndex(where: { $0.character == letter }) else { return }
        let top = (height - CGFloat(shown.count) * Self.rowHeight) / 2
        finger = top + (CGFloat(row) + 0.5) * Self.rowHeight
        current = letter
        callout = letter
        select(shown[row])
    }
    #endif
}

/// Where one rail letter sits in the lens, `offset` rows from the finger. The touched letter swells to 3.6×
/// and leans 46 pt out, the letters beside it to 2.5× and 32 pt, then 1.75× and 18 pt and 1.3× and 7 pt, and
/// the rest dim to 72%; between rows it blends. That is a stronger lens than Apollo's index (2.9× and
/// 27 pt), so the touched letter clears the thumb. The swollen letters would overlap at the rail's 16 pt row
/// pitch, so the rows part from the finger until the gap between two letters is a fixed margin; the rest of
/// the rail keeps its pitch, shifted by what the lens added. Under Reduce Motion only the touched letter
/// grows, to a size that fits its row, and nothing leans or shifts.
private struct LetterLens {
    var scale: CGFloat = 1
    var lean: CGFloat = 0
    var opacity: Double = 1
    /// Vertical displacement from the letter's row, pointing away from the finger.
    var shift: CGFloat = 0

    /// The touched letter's scale, the largest any letter is drawn at.
    static let peak: CGFloat = 3.6
    private static let scales: [CGFloat] = [peak, 2.5, 1.75, 1.3, 1]
    private static let leans: [CGFloat] = [46, 32, 18, 7, 0]
    private static let dimmed = 0.72
    /// The touched letter under Reduce Motion: a capital 14.6 pt tall at the default size, inside its row.
    private static let still: CGFloat = 1.85
    /// The rows the lens reaches past the touched one.
    private static let reach = CGFloat(scales.count - 1)
    /// A capital's height as a share of its font size, and the clear space kept between two capitals.
    private static let capHeight: CGFloat = 0.72
    private static let margin = Space.s1

    init(offset: CGFloat?, reduceMotion: Bool, row: CGFloat, glyph: CGFloat) {
        guard let offset, offset.isFinite else { return }
        let distance = abs(offset)
        if reduceMotion {
            if distance < 0.5 { scale = Self.still } else { opacity = Self.dimmed }
            return
        }
        scale = Self.scale(at: distance)
        let clamped = min(distance, Self.reach)
        let lower = Int(clamped)
        let upper = min(lower + 1, Self.scales.count - 1)
        lean = Self.leans[lower] + (Self.leans[upper] - Self.leans[lower]) * (clamped - CGFloat(lower))
        opacity = 1 - (1 - Self.dimmed) * Double(min(max(distance - Self.reach + 1, 0), 1))
        shift = (Self.position(distance, row: row, glyph: glyph) - distance * row) * (offset < 0 ? -1 : 1)
    }

    /// The scale `distance` rows from the finger, blended between the rows.
    private static func scale(at distance: CGFloat) -> CGFloat {
        let clamped = min(distance, reach)
        let lower = Int(clamped)
        let upper = min(lower + 1, scales.count - 1)
        return scales[lower] + (scales[upper] - scales[lower]) * (clamped - CGFloat(lower))
    }

    /// The height a capital shows at `distance` rows from the finger.
    static func height(of distance: CGFloat, glyph: CGFloat) -> CGFloat {
        glyph * capHeight * scale(at: distance)
    }

    /// How far `distance` rows from the finger a letter sits, in points, once the rows are parted: each
    /// step of one row grows to the height of the capital there plus the margin, and never shrinks below
    /// the row. Past the lens the step stays that of the unswollen letter.
    static func position(_ distance: CGFloat, row: CGFloat, glyph: CGFloat) -> CGFloat {
        let steps = 4
        let inside = min(distance, reach)
        let h = inside / CGFloat(steps)
        var total: CGFloat = 0
        for k in 0..<steps {
            total += max(row, height(of: (CGFloat(k) + 0.5) * h, glyph: glyph) + margin) * h
        }
        return total + max(distance - reach, 0) * max(row, height(of: reach, glyph: glyph) + margin)
    }
}
