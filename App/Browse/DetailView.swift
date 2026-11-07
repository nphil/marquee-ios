import MarqueeCore
import SwiftUI

/// A movie, show, season or episode on the server (DESIGN §8.3, §8.4).
struct DetailView: View {
    let ratingKey: String

    @Environment(\.plexLibrary) private var library
    @Environment(\.theme) private var theme
    @Environment(LibraryChanges.self) private var changes
    @State private var remote = Remote<PlexMetadata>()

    var body: some View {
        WidthReader { width in
            RemoteContent(remote: remote) { item in
                DetailPage(item: item, width: width) { watched in
                    withAnimation(Motion.label) {
                        remote.update { $0 = $0.markedWatched(watched) }
                    }
                }
            } skeleton: {
                DetailSkeleton(width: width)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.canvas)
        .task(id: LoadKey(library: library?.instance, attempt: remote.attempt, extra: changes.revision)) {
            guard let library else { return }
            let key = ratingKey
            await remote.load { try await library.metadata(key) }
        }
    }
}

/// A watchlist title (DESIGN §8.3 item 9): the server's copy when it has one, otherwise the catalogue's
/// details with no Play pill and "Not on your servers".
struct WatchlistDetailView: View {
    let item: PlexMetadata

    @Environment(\.plexLibrary) private var library
    @Environment(\.theme) private var theme
    @State private var match = Remote<PlexMetadata?>()

    var body: some View {
        WidthReader { width in
            RemoteContent(remote: match) { found in
                if let found {
                    DetailView(ratingKey: found.ratingKey)
                } else {
                    DetailPage(item: item, width: width, isOnServer: false)
                }
            } skeleton: {
                DetailSkeleton(width: width)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.canvas)
        .task(id: LoadKey(library: library?.instance, attempt: match.attempt)) {
            let guid = item.guid
            guard let library, let guid, PlexWatchlist.catalogueKey(guid: guid) != nil else {
                await match.load { nil }
                return
            }
            await match.load { try await library.items(matchingGuid: guid).first }
        }
    }
}

/// The page itself, for a title on the server or, with `isOnServer` off, a catalogue title.
private struct DetailPage: View {
    let item: PlexMetadata
    let width: CGFloat
    var isOnServer = true
    /// Shows the title watched or unwatched ahead of the server.
    var showWatched: @MainActor (Bool) -> Void = { _ in }

    @Environment(\.theme) private var theme
    @Environment(\.sessionActions) private var session
    @Environment(\.openRoute) private var openRoute
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showsBarTitle = false
    /// The status and navigation bars' height over the top of the page, which the hero reaches up under.
    @State private var barInset: CGFloat = 0
    @State private var version = 0
    @State private var showsTracks = false
    @State private var watchlisted: Bool? = nil
    @State private var extras: [PlexMetadata] = []
    @State private var deleting: DeleteTarget?
    @Environment(\.plexLibrary) private var library
    @Environment(\.dismiss) private var dismiss
    private let actions = ItemActions()

    /// A phone on its side: a full-width 16:9 hero would be taller than the screen, so the art becomes a
    /// card beside the title and Play stays on the first screen.
    private var isLandscape: Bool {
        verticalSizeClass == .compact
    }

    /// The backdrop's height at its natural 16:9, uncropped (DESIGN §8.3).
    private var heroHeight: CGFloat {
        (max(width, 1) * 9 / 16).rounded()
    }

    /// The art card in landscape: half the content width, at 16:9.
    private var cardSize: CGSize {
        let cardWidth = max(((width - Space.inset * 2 - Space.s6) / 2).rounded(.down), 1)
        return CGSize(width: cardWidth, height: (cardWidth * 9 / 16).rounded())
    }

    /// How far the page scrolls before the title moves into the bar: as the large title, which overlaps the
    /// backdrop's foot by `Space.s7`, slides under it.
    private var barTitlePoint: CGFloat {
        isLandscape ? Space.s8 : heroHeight - Space.s7
    }

    private var media: PlexMedia? {
        item.media.indices.contains(version) ? item.media[version] : item.media.first
    }

    private var tracks: MediaTracks? {
        guard let part = media?.parts.first else { return nil }
        let tracks = MediaTracks(part: part)
        return tracks.audio.isEmpty && tracks.visibleSubtitles.isEmpty ? nil : tracks
    }

    /// What Play starts: the title itself, or for a show the episode up next.
    private var playTarget: PlexMetadata? {
        guard isOnServer else { return nil }
        switch item.type {
        case .movie, .episode, .clip: return item
        case .show: return item.onDeck
        default: return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if isLandscape {
                    HStack(alignment: .top, spacing: Space.s6) {
                        DetailHero(item: item, size: cardSize, bleeds: false)
                        VStack(alignment: .leading, spacing: Space.s5) {
                            titleBlock
                            actionBlock
                        }
                    }
                    .padding(.horizontal, Space.inset)
                    .padding(.top, Space.s3)
                    VStack(alignment: .leading, spacing: Space.s5) {
                        details
                    }
                    .padding(.horizontal, Space.inset)
                    .padding(.top, Space.s6)
                } else {
                    DetailHero(item: item, size: CGSize(width: width, height: heroHeight), reach: barInset)
                    VStack(alignment: .leading, spacing: Space.s5) {
                        titleBlock
                        actionBlock
                        details
                    }
                    .padding(.horizontal, Space.inset)
                    .padding(.top, -Space.s7)
                }
                VStack(alignment: .leading, spacing: Space.s7) {
                    if !item.roles.isEmpty {
                        CastShelf(roles: item.roles)
                    }
                    if !extras.isEmpty {
                        ExtrasShelf(extras: extras)
                    }
                    if isOnServer, item.type == .movie || item.type == .show {
                        RelatedShelves(ratingKey: item.ratingKey)
                    }
                }
                .padding(.top, Space.s7)
            }
            .padding(.bottom, Space.s7)
        }
        .ignoresSafeArea(.container, edges: isLandscape ? [] : .top)
        // Read outside the edge the page ignores: inside it, the top inset is zero.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.safeAreaInsets.top
        } action: { top in
            barInset = top.isFinite ? max(top, 0) : 0
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .swipeActionsContainer()
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > barTitlePoint
        } action: { _, past in
            showsBarTitle = past
        }
        .navigationTitle(showsBarTitle ? item.title : "")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsTracks) {
            if let tracks {
                TracksSheet(tracks: tracks)
            }
        }
        .task(id: item.guid) {
            watchlisted = await actions.isWatchlisted(item.guid)
        }
        // Movie and show pages only: the extras of seasons and episodes are not shown.
        .task(id: item.ratingKey) {
            guard isOnServer, item.type == .movie || item.type == .show, let library else { return }
            extras = (try? await library.extras(of: item.ratingKey)) ?? []
        }
        .deleteConfirmation($deleting) { target in
            if case .title = target { dismiss() }
        }
    }

    /// Everything between the actions and the cast: the version, synopsis, tracks and episodes.
    @ViewBuilder
    private var details: some View {
        if let media, item.media.count > 1 {
            versionMenu(media)
        }
        if !item.summary.isEmpty {
            Synopsis(text: item.summary)
        }
        if let tracks {
            TracksRow(tracks: tracks) { showsTracks = true }
        }
        if isOnServer, item.type == .show || item.type == .season {
            SeasonsSection(parent: item)
        }
    }

    // MARK: Title

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            if item.type == .episode, let show = item.grandparentTitle, let showKey = item.grandparentRatingKey {
                Button {
                    openRoute(.item(ratingKey: showKey))
                } label: {
                    Text(show)
                        .textRole(.headline)
                        .foregroundStyle(theme.ink2)
                        .frame(minHeight: Size.target)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the show")
            }
            Text(item.title)
                .textRole(.display)
                .foregroundStyle(theme.ink)
                .lineLimit(3)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("detail.title")
            if let meta = metaText {
                meta
                    .textRole(.label)
                    .foregroundStyle(theme.ink2)
                    .monospacedDigit()
                    .accessibilityLabel(spokenMetaLine)
            }
            let chips = media?.formatChips ?? []
            if !chips.isEmpty {
                ChipFlow {
                    ForEach(chips, id: \.self) { Chip(title: $0) }
                }
            }
        }
    }

    private var ratingText: String? {
        (item.audienceRating ?? item.rating).map { $0.formatted(.number.precision(.fractionLength(1))) }
    }

    /// "2010 · 15 min · PG-13 · ★ 7.6": the rating ends the meta line, its star in ink2 like the words
    /// (DESIGN §5.2), rather than standing alone on a line of its own when a title has no format chips.
    private var metaText: Text? {
        let star = Image(systemName: "star.fill")
        switch (item.metaLine, ratingText) {
        case let (meta?, rating?): return Text("\(meta) · \(star) \(rating)")
        case let (meta?, nil): return Text(meta)
        case let (nil, rating?): return Text("\(star) \(rating)")
        case (nil, nil): return nil
        }
    }

    private var spokenMetaLine: String {
        [item.metaLine, ratingText.map { "rated \($0) out of 10" }].compactMap(\.self).joined(separator: ", ")
    }

    // MARK: Actions

    @ViewBuilder
    private var actionBlock: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            if let target = playTarget {
                Button {
                    session.play(target, mediaIndex: mediaIndex(for: target))
                } label: {
                    Label(playTitle(target), systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .contentTransition(.opacity)
                }
                .buttonStyle(.pill)
                .animation(Motion.label, value: playTitle(target))
                .accessibilityIdentifier("detail.play")
            } else if !isOnServer {
                Label("Not on your servers", systemImage: "server.rack")
                    .textRole(.body)
                    .foregroundStyle(theme.ink2)
                    .accessibilityIdentifier("detail.notOnServer")
            }
            HStack(spacing: Space.s4) {
                if let guid = item.guid, actions.canWatchlist(guid) {
                    let on = watchlisted ?? !isOnServer
                    Button {
                        actions.setWatchlisted(!on, guid: guid) { state in
                            withAnimation(Motion.label) { watchlisted = state }
                        }
                    } label: {
                        Image(systemName: on ? "bookmark.fill" : "bookmark")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.round)
                    .disabled(watchlisted == nil && isOnServer)
                    .accessibilityLabel(on ? "Remove from Watchlist" : "Add to Watchlist")
                }
                if isOnServer, item.type != .clip {
                    Button {
                        let watched = !item.isWatched
                        actions.setWatched(watched, item, show: showWatched)
                    } label: {
                        Image(systemName: item.isWatched ? "checkmark.circle.fill" : "checkmark.circle")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.round)
                    .accessibilityLabel(item.isWatched ? "Mark Unwatched" : "Mark Watched")
                }
                if isOnServer {
                    moreMenu
                }
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            if let target = playTarget, target.progress != nil {
                Button("Play from Beginning", systemImage: "arrow.counterclockwise") {
                    session.play(target, mediaIndex: mediaIndex(for: target), fromStart: true)
                }
            }
            if let trailer = ExtrasShelf.trailer(in: extras, primaryKey: item.primaryExtraKey) {
                Button("Play Trailer", systemImage: "film") { session.play(trailer) }
            }
            if item.media.count > 1 {
                Picker("Version", systemImage: "rectangle.stack", selection: $version) {
                    ForEach(item.media.indices, id: \.self) { Text(item.media[$0].versionLabel).tag($0) }
                }
                .pickerStyle(.menu)
            }
            if tracks != nil {
                Button("Audio & Subtitles", systemImage: "captions.bubble") { showsTracks = true }
            }
            if let url = shareURL {
                ShareLink(item: url, subject: Text(item.title)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            if session.canDeleteMedia, item.type == .movie || item.type == .show || item.type == .season || item.type == .episode {
                Section {
                    if item.media.count > 1 {
                        Button("Delete This Version…", systemImage: "trash", role: .destructive) {
                            deleting = .version(item, mediaIndex: version)
                        }
                    }
                    Button("Delete…", systemImage: "trash", role: .destructive) {
                        deleting = .title(item)
                    }
                    .accessibilityIdentifier("detail.delete")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.round)
        .contentShape(.contextMenuPreview, Circle())
        .accessibilityLabel("More")
    }

    private func versionMenu(_ media: PlexMedia) -> some View {
        Menu {
            Picker("Version", selection: $version) {
                ForEach(item.media.indices, id: \.self) { Text(item.media[$0].versionLabel).tag($0) }
            }
        } label: {
            MenuPill(title: media.versionLabel)
        }
        .capsuleMenuLabel()
        .accessibilityLabel("Version, \(media.versionLabel)")
    }

    /// "Play", "Resume · 42 min left", "Play S1 · E1" or "Resume S2 · E5" (DESIGN §8.3).
    private func playTitle(_ target: PlexMetadata) -> String {
        let resuming = target.progress != nil
        if item.type == .show, let code = target.episodeCode {
            return (resuming ? "Resume " : "Play ") + code
        }
        if resuming, let left = target.minutesLeft {
            return "Resume · " + ItemText.left(left)
        }
        return "Play"
    }

    /// The chosen version applies to this title only; an episode played from a show starts its first.
    private func mediaIndex(for target: PlexMetadata) -> Int {
        target.ratingKey == item.ratingKey ? version : 0
    }

    /// The catalogue page on plex.tv, which anyone can open.
    private var shareURL: URL? {
        guard let key = PlexWatchlist.catalogueKey(guid: item.guid) else { return nil }
        return URL(string: "https://app.plex.tv/desktop/#!/provider/tv.plex.provider.discover/details?key=%2Flibrary%2Fmetadata%2F\(key)")
    }
}

/// The backdrop at its natural 16:9, full width and uncropped, fading into the canvas over its lower part
/// (DESIGN §8.3). Above it, under the status and navigation bars, the art runs on as a blurred mirror of its
/// top edge, so it bleeds to the top of the screen without the bars hiding a third of it. With `bleeds`
/// off, a rounded card beside the title (landscape). Without a backdrop the poster stands in, blurred.
private struct DetailHero: View {
    let item: PlexMetadata
    let size: CGSize
    /// The bars' height above the backdrop.
    var reach: CGFloat = 0
    var bleeds = true

    @Environment(\.theme) private var theme

    var body: some View {
        if bleeds {
            VStack(spacing: 0) {
                if reach > 0 {
                    art
                        .scaleEffect(x: 1, y: -1)
                        .frame(height: min(reach, size.height), alignment: .bottom)
                        .clipped()
                        .blur(radius: Space.s6, opaque: true)
                }
                art
                    .overlay { fade }
            }
            .accessibilityHidden(true)
        } else {
            art
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    /// Eased, so the art keeps its colour longer than a straight ramp, and at 85% canvas where the title
    /// starts, `Space.s7` above the foot (DESIGN §5.3).
    private var fade: some View {
        let title = 1 - Space.s7 / max(size.height, 1)
        return LinearGradient(
            stops: [
                .init(color: theme.canvas.opacity(0), location: title - 0.45),
                .init(color: theme.canvas.opacity(0.2), location: title - 0.3),
                .init(color: theme.canvas.opacity(0.55), location: title - 0.15),
                .init(color: theme.canvas.opacity(0.85), location: title),
                .init(color: theme.canvas, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var art: some View {
        ZStack {
            if let path = item.type == .episode ? (item.thumb ?? item.backdropPath) : item.backdropPath {
                PlexArtView(path: path, size: size)
            } else {
                PlexArtView(path: item.posterPath, size: size)
                    .blur(radius: Space.s6, opaque: true)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Body text, three lines, with a chevron to show the rest (DESIGN §8.3).
private struct Synopsis: View {
    let text: String

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var shownHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(text)
                .textRole(.body)
                .foregroundStyle(theme.ink)
                .lineLimit(expanded ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownHeight = $0 }
                .background(alignment: .topLeading) {
                    Text(text)
                        .textRole(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                }
            if expanded || fullHeight > shownHeight + 1 {
                Button {
                    withAnimation(Motion.spring(reduceMotion: reduceMotion)) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.ink2)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .frame(width: Size.target, height: Size.target)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Show less" : "Show more")
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }
}

/// The row that opens the full track list.
private struct TracksRow: View {
    let tracks: MediaTracks
    let open: @MainActor () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: open) {
            HStack(spacing: Space.s3) {
                VStack(alignment: .leading, spacing: Space.s1 / 2) {
                    Text("Audio & Subtitles")
                        .textRole(.headline)
                        .foregroundStyle(theme.ink)
                    Text(summary)
                        .textRole(.label)
                        .foregroundStyle(theme.ink2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.ink2)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: Size.rowMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var summary: String {
        let audio = tracks.audio.first(where: \.isDefault) ?? tracks.audio.first
        let subtitles = tracks.visibleSubtitles.count
        return [
            audio?.label,
            subtitles == 0 ? "No subtitles" : (subtitles == 1 ? "1 subtitle" : "\(subtitles) subtitles"),
        ]
        .compactMap(\.self)
        .joined(separator: " · ")
    }
}

/// Every audio and subtitle track in technical terms (DESIGN §8.3 item 6): codec and channels, PCM and
/// Dolby chips, and the picture format only on image subtitles.
private struct TracksSheet: View {
    let tracks: MediaTracks

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !tracks.audio.isEmpty {
                    Section("Audio") {
                        ForEach(tracks.audio) { track in
                            TrackRow(title: track.label, detail: Self.audioDetail(track), chips: Self.audioChips(track))
                        }
                    }
                }
                if !tracks.visibleSubtitles.isEmpty {
                    Section("Subtitles") {
                        ForEach(tracks.visibleSubtitles) { track in
                            TrackRow(title: track.label, detail: Self.subtitleDetail(track), chips: Self.subtitleChips(track))
                        }
                    }
                }
            }
            .themedList(theme)
            .navigationTitle("Audio & Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private static func audioDetail(_ track: AudioTrack) -> String {
        [track.codec.uppercased(), channelLayout(track.channels)].compactMap(\.self).joined(separator: " · ")
    }

    private static func audioChips(_ track: AudioTrack) -> [String] {
        let codec = track.codec.lowercased()
        var chips: [String] = []
        if codec.hasPrefix("pcm") { chips.append("PCM") }
        if ["ac3", "eac3", "truehd"].contains(codec) { chips.append("Dolby") }
        if track.title?.localizedCaseInsensitiveContains("Atmos") == true { chips.append("Atmos") }
        return chips + track.badges.map(\.rawValue)
    }

    private static func subtitleDetail(_ track: SubtitleTrack) -> String {
        track.isExternal ? track.codec.uppercased() + " · External file" : track.codec.uppercased()
    }

    private static func subtitleChips(_ track: SubtitleTrack) -> [String] {
        (track.imageFormat.map { [$0] } ?? []) + track.badges.map(\.rawValue)
    }

    private static func channelLayout(_ channels: Int?) -> String? {
        switch channels {
        case nil: nil
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        case let count?: "\(count) channels"
        }
    }
}

private struct TrackRow: View {
    let title: String
    let detail: String
    let chips: [String]

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            Text(title)
                .textRole(.headline)
                .foregroundStyle(theme.ink)
            Text(detail)
                .textRole(.label)
                .foregroundStyle(theme.ink2)
            if !chips.isEmpty {
                ChipFlow {
                    ForEach(chips, id: \.self) { Chip(title: $0) }
                }
            }
        }
        .padding(.vertical, Space.s1)
        .listRowBackground(theme.sheet)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Seasons and episodes

/// A show's seasons under a season menu, or a season's own episodes (DESIGN §8.4).
private struct SeasonsSection: View {
    let parent: PlexMetadata

    @Environment(\.plexLibrary) private var library
    @Environment(\.theme) private var theme
    @Environment(LibraryChanges.self) private var changes
    @State private var seasons = Remote<[PlexMetadata]>()
    @State private var chosen: String? = nil

    var body: some View {
        RemoteContent(remote: seasons) { seasons in
            if let season = current(in: seasons) {
                VStack(alignment: .leading, spacing: Space.s3) {
                    if seasons.count > 1 {
                        Menu {
                            Picker("Season", selection: Binding(get: { season.ratingKey }, set: { chosen = $0 })) {
                                ForEach(seasons) { Text(Self.menuTitle($0)).tag($0.ratingKey) }
                            }
                        } label: {
                            MenuPill(title: season.title)
                        }
                        .capsuleMenuLabel()
                        .accessibilityLabel("Season, \(season.title)")
                        .accessibilityIdentifier("detail.seasonMenu")
                    } else if parent.type == .show {
                        Text(season.title)
                            .textRole(.title)
                            .foregroundStyle(theme.ink)
                            .accessibilityAddTraits(.isHeader)
                    }
                    EpisodeList(season: season)
                        .id(season.ratingKey)
                }
            }
        } skeleton: {
            Skeleton.Rows(artSize: CGSize(width: 128, height: 72))
                .padding(.horizontal, -Space.inset)
        }
        .task(id: LoadKey(library: library?.instance, attempt: seasons.attempt, extra: changes.revision)) {
            guard let library else { return }
            let parent = parent
            if parent.type == .season {
                await seasons.load { [parent] }
            } else {
                await seasons.load { try await library.children(of: parent.ratingKey) }
            }
        }
    }

    /// The chosen season; at first the one holding the episode up next, else the first with episodes left,
    /// passing over Specials.
    private func current(in seasons: [PlexMetadata]) -> PlexMetadata? {
        if let chosen, let season = seasons.first(where: { $0.ratingKey == chosen }) { return season }
        if let next = parent.onDeck?.parentRatingKey, let season = seasons.first(where: { $0.ratingKey == next }) { return season }
        let regular = seasons.filter { $0.index != 0 }
        return regular.first { ($0.unwatchedLeafCount ?? 0) > 0 } ?? regular.first ?? seasons.first
    }

    /// "Season 2 · 3 unwatched" in the season menu (DESIGN §8.4 item 5).
    private static func menuTitle(_ season: PlexMetadata) -> String {
        guard let left = season.unwatchedLeafCount, left > 0 else { return season.title }
        return "\(season.title) · \(left) unwatched"
    }
}

private struct EpisodeList: View {
    let season: PlexMetadata

    @Environment(\.plexLibrary) private var library
    @Environment(LibraryChanges.self) private var changes
    @State private var episodes = Remote<[PlexMetadata]>()
    private let actions = ItemActions()

    var body: some View {
        RemoteContent(remote: episodes) { episodes in
            LazyVStack(alignment: .leading, spacing: Space.s3) {
                ForEach(episodes) { episode in
                    EpisodeRow(episode: episode) { watched in
                        actions.setWatched(watched, episode) { shown in
                            withAnimation(Motion.label) {
                                self.episodes.update { list in
                                    guard let row = list.firstIndex(where: { $0.ratingKey == episode.ratingKey }) else { return }
                                    list[row] = list[row].markedWatched(shown)
                                }
                            }
                        }
                    }
                }
            }
        } skeleton: {
            Skeleton.Rows(artSize: CGSize(width: 128, height: 72))
                .padding(.horizontal, -Space.inset)
        }
        .task(id: LoadKey(library: library?.instance, attempt: episodes.attempt, extra: changes.revision)) {
            guard let library else { return }
            let key = season.ratingKey
            await episodes.load { try await library.children(of: key) }
        }
    }
}

/// One episode (DESIGN §8.4): the still with its progress, "5 · Name", runtime and air date, two lines of
/// synopsis, then a watched check and a More menu. A tap plays; a swipe marks it watched or unwatched.
private struct EpisodeRow: View {
    let episode: PlexMetadata
    let setWatched: @MainActor (Bool) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.sessionActions) private var session
    @Environment(\.openRoute) private var openRoute

    private static let still = CGSize(width: 128, height: 72)

    var body: some View {
        HStack(alignment: .top, spacing: Space.s1) {
            Button {
                session.play(episode)
            } label: {
                content
            }
            .buttonStyle(PressButtonStyle(cornerRadius: Radius.row))
            .accessibilityHint("Plays the episode")
            VStack(spacing: 0) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.ink2)
                    .frame(width: Size.target, height: Size.target)
                    .opacity(episode.isWatched ? 1 : 0)
                    .accessibilityHidden(true)
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.ink2)
                        .frame(width: Size.target, height: Size.target)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More for \(episode.title)")
            }
        }
        .swipeActions(edge: .leading) {
            Button(episode.isWatched ? "Unwatched" : "Watched", systemImage: episode.isWatched ? "circle" : "checkmark.circle") {
                setWatched(!episode.isWatched)
            }
            .tint(theme.accent)
        }
        .accessibilityActions {
            Button(episode.isWatched ? "Mark Unwatched" : "Mark Watched") { setWatched(!episode.isWatched) }
        }
    }

    private var content: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s2))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Space.s3))
        return layout {
            VStack(spacing: Space.s1) {
                PlexArtView(path: episode.thumb, size: Self.still)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                ProgressBar(value: episode.progress ?? 0)
                    .opacity(episode.progress == nil ? 0 : 1)
            }
            .frame(width: Self.still.width)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(title)
                    .textRole(.headline)
                    .foregroundStyle(theme.ink)
                if let line {
                    Text(line)
                        .textRole(.label)
                        .foregroundStyle(theme.ink2)
                        .monospacedDigit()
                }
                if !episode.summary.isEmpty {
                    Text(episode.summary)
                        .textRole(.caption)
                        .foregroundStyle(theme.ink2)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
        .frame(minHeight: Size.rowMin, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityIdentifier("episode.\(episode.ratingKey)")
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(episode.isWatched ? "Mark Unwatched" : "Mark Watched", systemImage: episode.isWatched ? "circle" : "checkmark.circle") {
            setWatched(!episode.isWatched)
        }
        Button("Play from Beginning", systemImage: "arrow.counterclockwise") {
            session.play(episode, fromStart: true)
        }
        Button("Details", systemImage: "info.circle") {
            openRoute(.item(ratingKey: episode.ratingKey))
        }
    }

    /// "5 · Name".
    private var title: String {
        episode.index.map { "\($0) · \(episode.title)" } ?? episode.title
    }

    /// "42 min · 7 Mar 2024", or the time left once started.
    private var line: String? {
        let time = episode.minutesLeft.map(ItemText.left) ?? ItemText.runtime(episode.duration)
        let parts = [time, ItemText.airDate(episode.originallyAvailableAt)].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var spokenLabel: String {
        var parts = [episode.index.map { "Episode \($0)" }, episode.title]
        if let left = episode.minutesLeft {
            parts.append(ItemText.spokenLeft(left))
        } else if episode.isWatched {
            parts.append("watched")
        }
        return parts.compactMap(\.self).joined(separator: ", ")
    }
}

// MARK: Cast and related

/// Circular photos at 72 pt with Caption names (DESIGN §8.3 item 7); initials where the server has no photo.
private struct CastShelf: View {
    let roles: [PlexRole]

    @Environment(\.theme) private var theme
    private static let photo: CGFloat = 72

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            ShelfHeader(title: "Cast")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Space.s3) {
                    ForEach(Array(roles.prefix(30).enumerated()), id: \.offset) { _, role in
                        if let id = role.id {
                            NavigationLink(value: Route.person(id: id, name: role.name, thumb: role.thumb)) {
                                card(role)
                            }
                            .buttonStyle(.press)
                            .accessibilityHint("Shows their titles in your libraries")
                        } else {
                            card(role)
                        }
                    }
                }
            }
            .contentMargins(.horizontal, Space.inset, for: .scrollContent)
            .scrollIndicators(.hidden)
        }
    }

    private func card(_ role: PlexRole) -> some View {
        VStack(spacing: Space.s1) {
            CastPhoto(role: role, size: Self.photo)
            Text(role.name)
                .textRole(.caption)
                .foregroundStyle(theme.ink)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let character = role.character, !character.isEmpty {
                Text(character)
                    .textRole(.caption)
                    .foregroundStyle(theme.ink2)
                    .lineLimit(1)
            }
        }
        .frame(width: Self.photo + Space.s5)
        .accessibilityElement(children: .combine)
    }
}

/// A cast photo, or the person's initials on the placeholder fill, as Contacts and the TV app show someone
/// without one: a row of identical silhouettes says nothing.
private struct CastPhoto: View {
    let role: PlexRole
    let size: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        if let thumb = role.thumb, !thumb.isEmpty {
            PlexArtView(path: thumb, size: CGSize(width: size, height: size), placeholder: "person.fill")
                .clipShape(Circle())
        } else {
            Text(initials)
                .font(.custom(Manrope.semiBold.rawValue, fixedSize: size * 0.36))
                .foregroundStyle(theme.ink2)
                .frame(width: size, height: size)
                .background(theme.trackOff, in: Circle())
                .accessibilityHidden(true)
        }
    }

    /// "HR" for Halina Reijn: the first letters of the first and last names.
    private var initials: String {
        let names = role.name.split(separator: " ")
        let letters = [names.first?.first, names.count > 1 ? names.last?.first : nil].compactMap(\.self)
        return String(letters).uppercased()
    }
}

/// The server's related titles as poster shelves; quietly absent when it has none or cannot say.
private struct RelatedShelves: View {
    let ratingKey: String

    @Environment(\.plexLibrary) private var library
    @State private var hubs: [PlexHub] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s7) {
            ForEach(hubs) { PosterShelf(hub: $0) }
        }
        .task(id: library?.instance) {
            guard let library else { return }
            let key = ratingKey
            let related = (try? await library.related(to: key)) ?? []
            hubs = related.filter { !$0.items.isEmpty }
        }
    }
}

/// The page's shape while it loads, in the layout the page will have.
private struct DetailSkeleton: View {
    let width: CGFloat

    @Environment(\.theme) private var theme
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        let landscape = verticalSizeClass == .compact
        Group {
            if landscape {
                let cardWidth = max(((width - Space.inset * 2 - Space.s6) / 2).rounded(.down), 1)
                HStack(alignment: .top, spacing: Space.s6) {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .fill(theme.trackOff)
                        .frame(width: cardWidth, height: (cardWidth * 9 / 16).rounded())
                    lines
                }
                .padding(.horizontal, Space.inset)
                .padding(.top, Space.s3)
            } else {
                VStack(alignment: .leading, spacing: Space.s4) {
                    // Below the bars like the backdrop, and filled on up under them like its mirror.
                    Color.clear
                        .frame(height: (max(width, 1) * 9 / 16).rounded())
                        .background(theme.trackOff, ignoresSafeAreaEdges: .top)
                    lines
                        .padding(.horizontal, Space.inset)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityHidden(true)
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Capsule().fill(theme.trackOff).frame(width: 220, height: 28)
            Capsule().fill(theme.trackOff).frame(width: 140, height: 14)
            Capsule().fill(theme.trackOff).frame(height: Size.target)
        }
    }
}

extension PlexMetadata {
    /// The title as it looks once marked watched or unwatched, before the server's copy arrives.
    func markedWatched(_ watched: Bool) -> PlexMetadata {
        var copy = self
        if let leafCount, leafCount > 0 {
            copy.viewedLeafCount = watched ? leafCount : 0
        } else {
            copy.viewCount = watched ? max(viewCount, 1) : 0
        }
        copy.viewOffset = 0
        return copy
    }
}
