import Foundation
import MarqueeCore
import Observation

/// The time the guide is drawn at. UI tests fix it, so the fixtures and the screenshots line up.
enum LiveClock {
    static func now() -> Date {
        #if DEBUG
        if let fixed = FakePlex.liveNow { return fixed }
        #endif
        return Date()
    }
}

/// The Live TV tab's data for one server and profile: the DVR, its channels and guide, the genre
/// filters and the recordings (docs/LIVE-TV.md §6). The last guide is kept on disk, so the tab draws at
/// once and still shows something with the server away.
@MainActor @Observable
final class LiveTVStore {
    enum Phase: Equatable {
        case loading
        case ready
        /// The server has no DVR.
        case noDVR
        case failed(String)
    }

    enum Category: Hashable, Identifiable {
        case all, favourites, recent
        case genre(LiveChannelFilter)

        var id: String {
            switch self {
            case .all: "all"
            case .favourites: "favourites"
            case .recent: "recent"
            case .genre(let filter): "genre-" + filter.key
            }
        }

        var title: String {
            switch self {
            case .all: "All"
            case .favourites: "Favourites"
            case .recent: "Recent"
            case .genre(let filter): filter.title
            }
        }
    }

    let live: PlexLiveTV
    let serverName: String
    private(set) var phase: Phase = .loading
    private(set) var dvr: LiveDVR?
    private(set) var guide: LiveGuide = .empty
    private(set) var filters: [LiveChannelFilter] = []
    private(set) var recordings = LiveRecordings()
    /// False until the server lets this profile see recordings; Home members and servers without
    /// Plex Pass are refused, and the record actions stay hidden for them.
    private(set) var canRecord = false
    private(set) var now = LiveClock.now()
    /// When the guide last arrived from the server.
    private(set) var refreshedAt: Date?
    /// Why the last refresh failed while an older guide stays on screen.
    private(set) var refreshProblem: String?
    private(set) var category: Category = .all
    /// The channel keys of the chosen genre; nil while they load.
    private(set) var genreKeys: Set<String>?
    private(set) var favourites: [String]
    /// Most recent first.
    private(set) var recents: [String]

    @ObservationIgnored private let lists: LiveLists
    @ObservationIgnored private let cache: GuideCache
    @ObservationIgnored private let serverID: String
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var genreCache: [String: Set<String>] = [:]

    /// The guide loads the next 3 hours first, then the rest of the day.
    static let firstSpan: TimeInterval = 3 * 60 * 60
    static let fullSpan: TimeInterval = 24 * 60 * 60
    /// A guide older than this reloads when the tab or the app comes back.
    static let staleAfter: TimeInterval = 10 * 60
    static let recentLimit = 10

    init(library: PlexLibrary, serverName: String, profile: String?) {
        live = PlexLiveTV(library: library)
        self.serverName = serverName
        serverID = library.server.id
        lists = LiveLists(server: library.server.id, profile: profile ?? "owner")
        favourites = lists.favourites
        recents = lists.recents
        cache = GuideCache(directory: Self.cacheDirectory, now: { LiveClock.now() })
    }

    // MARK: Channels shown

    var categories: [Category] {
        var list: [Category] = [.all, .favourites]
        if !recents.isEmpty { list.append(.recent) }
        return list + filters.map(Category.genre)
    }

    /// The channels of the chosen category, in lineup order (Recent: most recent first).
    var channels: [LiveChannel] {
        switch category {
        case .all:
            return guide.channels
        case .favourites:
            let keys = Set(favourites)
            return guide.channels.filter { keys.contains($0.id) }
        case .recent:
            return recents.compactMap { guide.channel($0) }
        case .genre:
            guard let genreKeys else { return [] }
            return guide.channels.filter { genreKeys.contains($0.id) }
        }
    }

    /// Every channel, for changing channel in the player.
    var lineup: [LiveChannel] { guide.channels }

    func select(_ category: Category) {
        guard category != self.category else { return }
        self.category = category
        guard case .genre(let filter) = category else {
            genreKeys = nil
            return
        }
        if let keys = genreCache[filter.key] {
            genreKeys = keys
            return
        }
        genreKeys = nil
        Task {
            let keys = (try? await live.channelKeys(in: filter)) ?? []
            genreCache[filter.key] = keys
            if self.category == category { genreKeys = keys }
        }
    }

    func isFavourite(_ channel: LiveChannel) -> Bool {
        favourites.contains(channel.id)
    }

    func toggleFavourite(_ channel: LiveChannel) {
        if let index = favourites.firstIndex(of: channel.id) {
            favourites.remove(at: index)
        } else {
            favourites.append(channel.id)
        }
        lists.favourites = favourites
    }

    func noteWatched(_ channel: LiveChannel) {
        recents.removeAll { $0 == channel.id }
        recents.insert(channel.id, at: 0)
        if recents.count > Self.recentLimit { recents.removeLast(recents.count - Self.recentLimit) }
        lists.recents = recents
    }

    func mark(for airing: LiveAiring) -> RecordingMark? {
        recordings.mark(for: airing)
    }

    // MARK: Loading

    /// Draws the saved guide at once, then loads the server's.
    func start() async {
        now = LiveClock.now()
        if guide.isEmpty, let saved = lists.dvr, let cached = await cache.load(server: serverID, dvr: saved.key) {
            dvr = saved
            guide = cached
            phase = .ready
        }
        await refresh()
    }

    /// Moves the clock on; a guide left in the background reloads (https://forums.plex.tv/t/909610).
    func tick() {
        now = LiveClock.now()
        if let refreshedAt, now.timeIntervalSince(refreshedAt) > Self.staleAfter, refreshing == nil {
            Task { await refresh() }
        }
    }

    func refresh() async {
        if let refreshing {
            await refreshing.value
            return
        }
        let task = Task { await load() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func load() async {
        now = LiveClock.now()
        let now = now
        do {
            guard let dvr = try await live.dvrs().first else {
                self.dvr = nil
                guide = .empty
                phase = .noDVR
                return
            }
            self.dvr = dvr
            lists.dvr = dvr
            async let channelList = live.channels(dvr)
            async let filterList = try? live.channelFilters(dvr)
            async let recordingList: Void = loadRecordings()
            let channels = try await channelList
            let from = now.addingTimeInterval(-GuideCache.history)
            let middle = now.addingTimeInterval(Self.firstSpan)
            let end = now.addingTimeInterval(Self.fullSpan)
            let first = try await live.guide(dvr, channels: channels, from: from, to: middle)
            guide = LiveGuide(channels: channels, airings: first, from: from, to: middle)
            filters = await filterList ?? []
            phase = .ready
            refreshProblem = nil
            refreshedAt = now
            await recordingList
            let rest = try await live.guide(dvr, channels: channels, from: middle, to: end)
            guide = guide.merging(rest, from: middle, to: end)
            await cache.save(guide, server: serverID, dvr: dvr.key)
        } catch {
            let message = LiveText.problem(error, server: serverName)
            if guide.isEmpty {
                phase = .failed(message)
            } else {
                refreshProblem = message
                phase = .ready
            }
        }
    }

    // MARK: Recordings

    func loadRecordings() async {
        do {
            async let rules = live.rules()
            async let scheduled = live.scheduled()
            recordings = try await LiveRecordings(rules: rules, scheduled: scheduled)
            canRecord = true
        } catch PlexError.unauthorized {
            canRecord = false
        } catch PlexError.server(let status, _) where status == 401 || status == 403 {
            canRecord = false
        } catch {
            // The marks shown stay until the next load.
        }
    }

    func recordOptions(for airing: LiveAiring) async throws -> [RecordOption] {
        try await live.recordOptions(airing)
    }

    /// Creates the rule, then reads the schedule back: the server books airings a moment after it
    /// answers, so a second read follows when the first does not show the airing yet.
    func record(_ option: RecordOption, values: [String: String], airing: LiveAiring) async throws {
        try await live.record(option, values: values)
        await loadRecordings()
        if recordings.mark(for: airing) == nil {
            try? await Task.sleep(for: .seconds(2))
            await loadRecordings()
        }
    }

    func cancel(_ recording: ScheduledRecording) async throws {
        try await live.cancel(recording)
        await loadRecordings()
    }

    /// Deletes the rule, ending the airings it is recording first: deleting a rule alone leaves a grab
    /// under way holding its tuner.
    func delete(_ rule: RecordingRule) async throws {
        try await live.delete(rule, stopping: recordings.running(under: rule))
        await loadRecordings()
    }

    func update(_ rule: RecordingRule, values: [String: String]) async throws {
        try await live.update(rule, values: values)
        await loadRecordings()
    }

    /// Takes `airing` off the schedule, or stops it when it is recording.
    func unschedule(_ airing: LiveAiring, deletingSeries: Bool = false) async throws {
        guard let recording = recordings.recording(of: airing) else { return }
        try await unschedule(recording, deletingSeries: deletingSeries)
    }

    /// An airing under way stops: its grab is deleted, which frees the tuner, and so is a one-off
    /// rule, or a series rule when `deletingSeries`. An upcoming airing of a one-off rule deletes the
    /// rule, since a skipped airing comes back when the server restarts; under a series the airing
    /// alone is skipped.
    func unschedule(_ recording: ScheduledRecording, deletingSeries: Bool = false) async throws {
        if recording.status == .inprogress {
            try await live.stop(recording, deleting: recordings.rule(deletedWhenStopping: recording, deletingSeries: deletingSeries))
            await loadRecordings()
        } else if let rule = recordings.rule(recording.ruleID), !rule.isSeries {
            try await delete(rule)
        } else {
            try await cancel(recording)
        }
    }

    /// Whether stopping `recording` can also delete a series rule, which the stop confirmation offers.
    func offersSeriesDeletion(_ recording: ScheduledRecording) -> Bool {
        recording.status == .inprogress && recordings.rule(recording.ruleID)?.isSeries == true
    }

    /// The recording that has taken the tuner `channel` needs, read fresh from the server.
    func tunerHolder(for channel: LiveChannel) async -> ScheduledRecording? {
        await loadRecordings()
        return recordings.holdingTuner(for: channel, dvr: dvr)
    }

    var seriesRules: [RecordingRule] {
        recordings.rules.filter(\.isSeries).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Airings due to record, recording now, or that failed, soonest first.
    var upcoming: [ScheduledRecording] {
        recordings.scheduled.filter { $0.isUpcoming || $0.status == .error }
    }

    /// Completed DVR recordings across the server’s movie and TV libraries.
    func recorded() async throws -> [PlexMetadata] {
        try await live.library.recordedItems()
    }

    private static var cacheDirectory: URL {
        #if DEBUG
        if FakePlex.isActive {
            return FileManager.default.temporaryDirectory.appending(path: "LiveGuide-\(UUID().uuidString)", directoryHint: .isDirectory)
        }
        #endif
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appending(path: "LiveGuide", directoryHint: .isDirectory)
    }
}

/// Favourites, recent channels and the last DVR, per server and profile. UI-test launches start from an
/// emptied suite, as the session storage does.
@MainActor
private final class LiveLists {
    private let defaults: UserDefaults
    private let prefix: String

    init(server: String, profile: String) {
        prefix = "marquee.live.\(server).\(profile)."
        #if DEBUG
        if FakePlex.isActive {
            let suite = "com.nphil.marquee.uitest.live"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            for (key, value) in FakePlex.liveSeeds { defaults.set(value, forKey: prefix + key) }
            self.defaults = defaults
            return
        }
        #endif
        defaults = .standard
    }

    var favourites: [String] {
        get { defaults.stringArray(forKey: prefix + "favourites") ?? [] }
        set { defaults.set(newValue, forKey: prefix + "favourites") }
    }

    var recents: [String] {
        get { defaults.stringArray(forKey: prefix + "recents") ?? [] }
        set { defaults.set(newValue, forKey: prefix + "recents") }
    }

    var dvr: LiveDVR? {
        get { defaults.data(forKey: prefix + "dvr").flatMap { try? JSONDecoder().decode(LiveDVR.self, from: $0) } }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: prefix + "dvr") }
    }
}
