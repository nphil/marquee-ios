import Foundation
import Synchronization

/// Where an episode sits in its show: the season, then the number in it.
struct EpisodePosition: Comparable, Sendable {
    var season: Int
    var number: Int

    static let start = EpisodePosition(season: 0, number: 0)

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.season, lhs.number) < (rhs.season, rhs.number)
    }
}

extension PlexMetadata {
    /// An episode's place in its show: its season, then its number; a special is in season 0. Nil without
    /// its numbers, which leave it nowhere to be placed.
    var showPosition: EpisodePosition? {
        guard type == .episode, let season = parentIndex, let number = index else { return nil }
        return EpisodePosition(season: season, number: number)
    }

    /// Whether this episode was viewed after `other`. A tie, which a bulk "mark watched" leaves, goes to
    /// the later episode, so a show marked watched ends on its last episode.
    fileprivate func wasViewed(after other: PlexMetadata) -> Bool {
        if let mine = lastViewedAt, let theirs = other.lastViewedAt, mine != theirs { return mine > theirs }
        return (showPosition ?? .start) > (other.showPosition ?? .start)
    }
}

/// Continue Watching for a show watched again. Plex lists an episode there while it is part watched, or
/// next for a show not yet finished, so a show seen again from its start, every episode watched before,
/// drops out as soon as an episode is finished. From the profile's own recent views this puts the episode
/// after the latest view into the row (DESIGN §8.1).
///
/// A show's latest view `E` is its most recently viewed episode, a special too. A part-watched `E` is in
/// Plex's row already. Otherwise the next episode `N` is the first after `E` by season, then number,
/// across seasons and skipping specials, so a special leads to the show's first episode; none means the
/// series ended. Against Plex's own entry `P` for the show, a part-watched `P` viewed after `E` stays, and
/// so does an unwatched `P` that comes after `E`. Anything else gives way to `N`, or to nothing when the
/// profile took `N` off the row.
struct RewatchQueue: Sendable {
    /// How far back a view counts: 16 weeks.
    static let window: TimeInterval = 16 * 7 * 86_400
    /// Shows whose next episode is looked up at once, newest views first.
    static let maxLookups = 10
    /// Cards in the row, as many as Home asks Plex for.
    static let rowSize = 12

    /// The latest views whose next episode the row needs, newest first, at most `maxLookups`.
    let lookups: [PlexMetadata]
    private let plex: [PlexMetadata]
    private let latest: [String: PlexMetadata]
    /// Shows whose Plex entry goes, as the card that would replace it was taken off the row.
    private let removed: Set<String>

    /// `views` are episodes the profile has viewed, `plex` is Plex's Continue Watching row, and `server`
    /// names the server for `dismissed`.
    init(views: [PlexMetadata], plex: [PlexMetadata], dismissed: RewatchDismissals, server: String, now: Date = Date()) {
        let latest = Self.latestViews(in: views, since: now.addingTimeInterval(-Self.window))
        var needing: [PlexMetadata] = []
        var removed: Set<String> = []
        for viewed in latest.values.sorted(by: { $0.wasViewed(after: $1) }) {
            guard viewed.viewOffset == 0, let show = viewed.grandparentRatingKey else { continue }
            let card = plex.first { $0.type == .episode && $0.grandparentRatingKey == show }
            if let card, Self.keeps(card, over: viewed) { continue }
            if !dismissed.hides(viewed, on: server) {
                needing.append(viewed)
            } else if card != nil {
                removed.insert(show)
            }
        }
        self.plex = plex
        self.latest = latest
        self.removed = removed
        lookups = Array(needing.prefix(Self.maxLookups))
    }

    /// Each show's latest view: the episode viewed most recently, no earlier than `cutoff`.
    static func latestViews(in episodes: [PlexMetadata], since cutoff: Date) -> [String: PlexMetadata] {
        var latest: [String: PlexMetadata] = [:]
        for episode in episodes {
            guard let show = episode.grandparentRatingKey, let at = episode.lastViewedAt, at > cutoff, episode.showPosition != nil else { continue }
            if let current = latest[show], !episode.wasViewed(after: current) { continue }
            latest[show] = episode
        }
        return latest
    }

    /// Whether Plex's `card` for a show is at least as current as the show's latest view.
    fileprivate static func keeps(_ card: PlexMetadata, over viewed: PlexMetadata) -> Bool {
        if card.viewOffset > 0 {
            guard let cardViewed = card.lastViewedAt, let viewedAt = viewed.lastViewedAt else { return true }
            return cardViewed > viewedAt
        }
        guard card.viewCount == 0, let cardAt = card.showPosition, let viewedAt = viewed.showPosition else { return false }
        return cardAt > viewedAt
    }

    /// The first episode of `episodes` after `position`, or the first of all without one; season, then
    /// number, and never a special.
    static func next(after position: EpisodePosition?, in episodes: [PlexMetadata]) -> PlexMetadata? {
        var best: (episode: PlexMetadata, position: EpisodePosition)?
        for episode in episodes {
            guard let at = episode.showPosition, at.season > 0 else { continue }
            if let position, at <= position { continue }
            if let best, best.position <= at { continue }
            best = (episode, at)
        }
        return best?.episode
    }

    /// Plex's row with each show in `lookups` that has a next episode in `next` (by show) given that
    /// episode as its card. A card is placed by when its show was last viewed, among Plex's in their own
    /// order. A show without a next episode keeps Plex's entry; one whose card the profile took off loses it.
    func merged(next: [String: PlexMetadata]) -> [PlexMetadata] {
        var cards: [(viewedAt: Date, card: PlexMetadata)] = []
        var replaced = removed
        for viewed in lookups {
            guard let show = viewed.grandparentRatingKey, let viewedAt = viewed.lastViewedAt, var card = next[show] else { continue }
            // Plex's own cards for a next episode show no progress, and this one plays from its start.
            card.viewOffset = 0
            card.rewatchedAt = viewedAt
            card.grandparentGuid = card.grandparentGuid ?? viewed.grandparentGuid
            card.librarySectionID = card.librarySectionID ?? viewed.librarySectionID
            card.librarySectionTitle = card.librarySectionTitle ?? viewed.librarySectionTitle
            cards.append((viewedAt, card))
            replaced.insert(show)
        }
        guard !replaced.isEmpty else { return plex }
        var row: [PlexMetadata] = []
        var waiting = cards[...]
        for entry in plex where entry.type != .episode || !replaced.contains(entry.grandparentRatingKey ?? "") {
            if let activity = activity(of: entry) {
                while let first = waiting.first, first.viewedAt > activity {
                    row.append(first.card)
                    waiting = waiting.dropFirst()
                }
            }
            row.append(entry)
        }
        row += waiting.map { $0.card }
        return Array(row.prefix(max(Self.rowSize, plex.count)))
    }

    /// When Plex's `entry` last saw activity: its own last view, else its show's latest view.
    private func activity(of entry: PlexMetadata) -> Date? {
        entry.lastViewedAt ?? entry.grandparentRatingKey.flatMap { latest[$0]?.lastViewedAt }
    }
}

/// The shows whose next-episode card the profile took off Continue Watching. Each is kept with when the
/// show was last viewed, and the card stays off, and Plex's entry it replaced with it, until a view after
/// that. A show is told apart by its guid, which every server and device agrees on; one without a guid is
/// off for the session only, as its key on a server means nothing beyond it. Plex's own cards are the
/// server's to remove, so they are not tracked here.
public struct RewatchDismissals: Codable, Hashable, Sendable {
    private var viewed: [String: Date] = [:]
    private var session: [String: Date] = [:]

    private enum CodingKeys: String, CodingKey { case viewed }

    public init() {}

    /// Where a show is kept: by its guid, else by its key on `server`, for the session.
    private static func entry(of episode: PlexMetadata, on server: String) -> (key: String, lasts: Bool)? {
        if let guid = episode.grandparentGuid, !guid.isEmpty { return (guid, true) }
        return episode.grandparentRatingKey.map { ("\(server)/\($0)", false) }
    }

    /// Whether the card made from `view`, a view of an episode of its show, stays off the row.
    func hides(_ view: PlexMetadata, on server: String) -> Bool {
        guard let at = view.lastViewedAt, let entry = Self.entry(of: view, on: server) else { return false }
        return (entry.lasts ? viewed : session)[entry.key].map { at <= $0 } ?? false
    }

    /// Takes the next-episode `card` off the row for the view it was made from. Dismissals of views older
    /// than the window are dropped, as no card is made from those.
    public mutating func dismiss(_ card: PlexMetadata, on server: String, now: Date = Date()) {
        guard let at = card.rewatchedAt, let entry = Self.entry(of: card, on: server) else { return }
        viewed = viewed.filter { now.timeIntervalSince($0.value) <= RewatchQueue.window }
        if entry.lasts { viewed[entry.key] = at } else { session[entry.key] = at }
    }

    /// Undoes `dismiss`.
    public mutating func restore(_ card: PlexMetadata, on server: String) {
        guard let entry = Self.entry(of: card, on: server) else { return }
        if entry.lasts { viewed[entry.key] = nil } else { session[entry.key] = nil }
    }
}

/// One look at what the profile has been watching, begun when Home starts loading so it runs beside
/// Plex's own answer. `continuing(_:dismissed:within:)` then puts the shows watched again into that answer.
/// The reads belong to the run, so a caller that stops waiting leaves them going for the next one.
public final class RewatchRun: Sendable {
    private let library: PlexLibrary
    private let now: Date
    private let started = ContinuousClock.now
    private let history: Task<[PlexMetadata], Never>
    /// The next-episode reads begun so far, by the latest view they follow.
    private let lookups = Mutex<[String: Task<PlexMetadata?, Never>]>([:])

    /// Starts reading the profile's recent views in each library of shows that is not in `hidden` (by
    /// `HomeLayout.libraryID`).
    public init(library: PlexLibrary, hidden: Set<String>, now: Date = Date()) {
        self.library = library
        self.now = now
        let cutoff = now.addingTimeInterval(-RewatchQueue.window)
        history = Task { await library.recentViews(hidden: hidden, since: cutoff) }
    }

    /// Stops the reads, for a load that no longer matters. A cancelled run answers nothing more.
    public func cancel() {
        history.cancel()
        lookups.withLock { tasks in tasks.values.forEach { $0.cancel() } }
    }

    /// `plex`, Plex's Continue Watching cards, with the shows watched again in it. Nil when that takes
    /// longer than `limit` (no limit without one), or the run is cancelled. A show whose next episode
    /// cannot be found keeps Plex's own entry.
    public func continuing(_ plex: [PlexMetadata], dismissed: RewatchDismissals, within limit: Duration? = nil) async -> [PlexMetadata]? {
        guard !history.isCancelled else { return nil }
        return await withTaskCancellationHandler {
            guard let limit else { return await resolve(plex, dismissed) }
            return await TimeLimit.answer(within: limit) { await self.resolve(plex, dismissed) }
        } onCancel: {
            self.cancel()
        }
    }

    private func resolve(_ plex: [PlexMetadata], _ dismissed: RewatchDismissals) async -> [PlexMetadata]? {
        let views = await history.value
        let queue = RewatchQueue(views: views, plex: plex, dismissed: dismissed, server: library.server.clientIdentifier, now: now)
        var reads: [(show: String, read: Task<PlexMetadata?, Never>)] = []
        for viewed in queue.lookups {
            if let show = viewed.grandparentRatingKey { reads.append((show, lookup(viewed))) }
        }
        var next: [String: PlexMetadata] = [:]
        for (show, read) in reads { next[show] = await read.value }
        guard !history.isCancelled else { return nil }
        let row = queue.merged(next: next)
        let added = row.filter { $0.rewatchedAt != nil }.count
        DiagHub.emit(.plex, "rewatch", [
            "views": views.count, "lookups": queue.lookups.count, "found": next.count, "plex": plex.count,
            "added": added, "replaced": plex.count - (row.count - added), "ms": Int((ContinuousClock.now - started) / .milliseconds(1)),
        ])
        return row
    }

    /// The read of the episode after `viewed`, begun now unless an earlier call began it. A read that
    /// fails comes out as no next episode.
    private func lookup(_ viewed: PlexMetadata) -> Task<PlexMetadata?, Never> {
        let library = library
        return lookups.withLock { tasks in
            if let task = tasks[viewed.ratingKey] { return task }
            let task = Task { try? await library.episode(after: viewed) }
            tasks[viewed.ratingKey] = task
            return task
        }
    }
}

extension PlexLibrary {
    /// The episodes this profile viewed within the window, newest first, in each library of shows that is
    /// not in `hidden`. A read that fails leaves its library out.
    func recentViews(hidden: Set<String>, since cutoff: Date) async -> [PlexMetadata] {
        guard let sections = try? await sections() else { return [] }
        let shows = sections.filter { $0.type == .show && !hidden.contains(HomeLayout.libraryID($0)) }
        return await withTaskGroup(of: [PlexMetadata].self) { group in
            for section in shows {
                group.addTask { await self.recentViews(inSection: section.key, since: cutoff) }
            }
            var views: [PlexMetadata] = []
            for await episodes in group { views += episodes }
            return views
        }
    }

    /// One library's views, a page at a time while there are too few shows in them. Each page leaves out
    /// the shows already seen, so a binge of one show does not fill every page; a show's first view in a
    /// page is its latest.
    private func recentViews(inSection key: String, since cutoff: Date) async -> [PlexMetadata] {
        let pageSize = 50, maxPages = 4, showsWanted = 12
        var views: [PlexMetadata] = []
        var shows: [String] = []
        for _ in 0..<maxPages {
            guard let page = try? await viewedEpisodes(in: key, skipping: shows, since: cutoff, size: pageSize) else { break }
            // In the order met, so the next page asks for the same list however often this runs.
            var new: [String] = []
            for show in page.items.compactMap(\.grandparentRatingKey) where !shows.contains(show) && !new.contains(show) { new.append(show) }
            // A server that ignores the filter sends the same page again.
            guard !new.isEmpty else { break }
            views += page.items
            shows += new
            if page.items.count < pageSize || shows.count >= showsWanted { break }
        }
        return views
    }

    /// The episode after `viewed` in its show: the next of its season, else the first of the next season
    /// with episodes; after a special, the show's first. Nil at the end of the series. Throws when a read
    /// fails, so a failure never reads as the end.
    func episode(after viewed: PlexMetadata) async throws -> PlexMetadata? {
        guard let show = viewed.grandparentRatingKey, let season = viewed.parentRatingKey, let position = viewed.showPosition else { return nil }
        // No special is next, so the season of one is not read.
        if position.season > 0 {
            let siblings = try await children(of: season)
            if let next = RewatchQueue.next(after: position, in: siblings) { return next }
        }
        let later = try await children(of: show)
            .filter { $0.type == .season && ($0.index ?? 0) > position.season }
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        for season in later {
            let episodes = try await children(of: season.ratingKey)
            if let first = RewatchQueue.next(after: nil, in: episodes) { return first }
        }
        return nil
    }

    /// `show` as it is, or with the episode after its latest view up next when that is what Continue
    /// Watching offers: Plex's own up next gives way as it does there, and a show watched through, with
    /// none, gets one. A show ended by that view, or a failed read, is as it was. No window applies: the
    /// page is for this show, whenever it was watched.
    public func offeringRewatch(of show: PlexMetadata) async -> PlexMetadata {
        guard show.type == .show, show.viewedLeafCount ?? 0 > 0,
              let views = try? await viewedEpisodes(in: nil, ofShow: show.ratingKey, size: 12),
              let viewed = RewatchQueue.latestViews(in: views.items, since: .distantPast)[show.ratingKey],
              viewed.viewOffset == 0, show.onDeck.map({ !RewatchQueue.keeps($0, over: viewed) }) ?? true,
              var next = try? await episode(after: viewed) else { return show }
        next.viewOffset = 0
        next.rewatchedAt = viewed.lastViewedAt
        return show.settingOnDeck(next)
    }
}
