import MarqueeCore
import Observation

/// "Wrong Subtitles?" for one item (DESIGN §8.6): removing the subtitle file on screen from Plex, and
/// finding another with Plex's own agents or with Bazarr. It lasts as long as the item plays, so a search
/// and its downloads are where they were when the sheet opens again.
@MainActor @Observable
final class SubtitleFix {
    enum Removal: Equatable {
        case removing
        case removed
        case refused
        case unreachable
    }

    enum Search: Equatable {
        case searching
        case found([BazarrSubtitle])
        case failed(BazarrError)
    }

    /// Plex's agents search one language at a time.
    enum PlexSearch: Equatable {
        case searching
        case found([PlexSubtitleCandidate])
        case failed(unreachable: Bool)
    }

    /// Where one download stands. Neither Bazarr nor Plex reports progress, so every state is a step the
    /// app saw happen.
    enum Download: Equatable {
        case requesting
        /// Waiting for Plex to list the file: after Bazarr or Plex took the request, or for Check Plex
        /// Again.
        case waiting(afterBazarr: Bool)
        case notVisible
        case checkFailed
        case loading(track: Int)
        /// Plex lists the file as this track.
        case listed(track: Int)
        case playerFailed(track: Int)
        case failed(BazarrError)
        /// Plex would not add a file its agents found, or could not be reached.
        case notAdded(unreachable: Bool)

        var isBusy: Bool {
            switch self {
            case .requesting, .waiting, .loading: true
            default: false
            }
        }

        /// Plex may hold the file already: a timed-out request can still have been carried out.
        var canCheckPlex: Bool {
            switch self {
            case .notVisible, .checkFailed, .failed(.timedOut), .failed(.unreachable), .notAdded(unreachable: true): true
            default: false
            }
        }

        /// The track Plex lists the file as, once it does.
        var track: Int? {
            switch self {
            case .loading(let track), .listed(let track), .playerFailed(let track): track
            default: nil
            }
        }
    }

    let ratingKey: String
    private(set) var removal: Removal?
    private(set) var search: Search?
    /// The language Bazarr's results are listed in.
    var language: TrackLanguage
    private(set) var downloads: [BazarrSubtitle.ID: Download] = [:]
    private(set) var requestedBazarr: [BazarrSubtitle] = []
    private(set) var plexSearch: PlexSearch?
    /// Attempt keys remain available even after Plex replaces its search keys.
    private(set) var plexDownloads: [PlexSubtitleCandidate.ID: Download] = [:]
    private(set) var requestedPlex: [PlexSubtitleCandidate] = []

    @ObservationIgnored private weak var model: PlayerModel?
    @ObservationIgnored private var target: BazarrTarget?
    /// The track ids Plex listed before each download, so the file it adds can be told apart.
    @ObservationIgnored private var before: [BazarrSubtitle.ID: Set<Int>] = [:]
    @ObservationIgnored private var plexBefore: [PlexSubtitleCandidate.ID: Set<Int>] = [:]
    /// Unresolved Plex adds that no longer block; checked again by hand, they block until they settle.
    private var setAside: Set<PlexSubtitleCandidate.ID> = []
    @ObservationIgnored private var removeTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var plexSearchTask: Task<Void, Never>?

    /// Seconds between reads of the item while Plex finds a downloaded file: 19 s in all.
    private static let plexWaits: [Double] = [1, 2, 3, 5, 8]

    init(model: PlayerModel, language: TrackLanguage) {
        self.model = model
        ratingKey = model.item.ratingKey
        self.language = TrackLanguage.all.first { $0.matches(language) } ?? .english
    }

    /// The sheet opened again: an old removal's outcome is no longer news, and a Plex add still
    /// unresolved from the last visit no longer blocks.
    func open() {
        if removal != .removing { removal = nil }
        if !isDownloading { setAsidePlexCheck() }
    }

    func cancel() {
        for task in [removeTask, searchTask, downloadTask, plexSearchTask] { task?.cancel() }
    }

    /// One download at a time, from either search: each finds its file by what Plex lists anew.
    var isDownloading: Bool {
        downloads.values.contains(where: \.isBusy) || plexDownloads.values.contains(where: \.isBusy)
    }

    /// A Plex add may still complete after a timeout; keep its search keys valid until discovery succeeds.
    /// An attempt Plex never lists would block everything else for good, so one that stays unresolved
    /// can be set aside; it keeps its keys, so the same file is not added twice.
    var plexAddUnresolved: Bool {
        plexDownloads.contains { $0.value.isBusy || ($0.value.canCheckPlex && !setAside.contains($0.key)) }
    }

    /// An unresolved Plex add is waiting with nothing in flight, so it can be set aside.
    var canSetAsidePlexCheck: Bool {
        plexAddUnresolved && !isDownloading
    }

    /// Stops an unresolved Plex add from blocking language, search and other downloads.
    func setAsidePlexCheck() {
        setAside.formUnion(plexDownloads.filter { $0.value.canCheckPlex }.keys)
    }

    // MARK: Remove

    /// Deletes a subtitle file from the server. The video file is never touched.
    func remove(_ track: SubtitleTrack) {
        guard let model, track.isExternal, removal != .removing else { return }
        removal = .removing
        removeTask = Task { [weak self] in
            do {
                try await model.library.removeSubtitle(streamID: track.id)
            } catch {
                guard !Task.isCancelled else { return }
                Haptics.error()
                self?.removal = Self.isUnreachable(error) ? .unreachable : .refused
                return
            }
            Haptics.success()
            guard let self else { return }
            removal = .removed
            // A downloaded file that was just removed is no longer in Plex; its result can be had again.
            downloads = downloads.filter { $0.value.track != track.id }
            plexDownloads = plexDownloads.filter { $0.value.track != track.id }
            requestedBazarr.removeAll { self.downloads[$0.id] == nil }
            requestedPlex.removeAll { self.plexDownloads[$0.id] == nil }
            await model.removed(track)
        }
    }

    // MARK: Bazarr

    func searchIfNeeded() {
        guard search == nil, plexSearch == nil else { return }
        if model?.bazarr != nil { searchAgain() } else { searchPlex(in: language) }
    }

    func selectLanguage(_ selected: TrackLanguage) {
        guard !plexAddUnresolved, selected != language else { return }
        language = selected
        plexSearchTask?.cancel()
        plexSearch = nil
        if case .searching = search { return }
        if results.isEmpty { searchPlex(in: selected) }
    }

    func searchAgain() {
        guard let model, let client = model.bazarr else { return }
        searchTask?.cancel()
        search = .searching
        searchTask = Task { [weak self] in
            let outcome: Search
            do {
                let lookup = await model.bazarrLookup()
                let target = try await client.find(lookup)
                let found = try await client.search(target)
                guard !Task.isCancelled else { return }
                self?.target = target
                outcome = .found(found)
            } catch {
                outcome = .failed(error as? BazarrError ?? .unreachable)
            }
            guard !Task.isCancelled else { return }
            self?.search = outcome
            if let self, self.results.isEmpty, self.plexSearch == nil { self.searchPlex(in: self.language) }
        }
    }


    /// The results in the chosen language, best match first.
    var results: [BazarrSubtitle] {
        guard case .found(let results) = search else { return [] }
        return results.filter { $0.trackLanguage.matches(language) }
    }

    /// Never one result twice.
    func canDownload(_ result: BazarrSubtitle) -> Bool {
        downloads[result.id] == nil && !isDownloading && !plexAddUnresolved && target != nil
    }

    func download(_ result: BazarrSubtitle) {
        guard canDownload(result), let model, let client = model.bazarr, let target else { return }
        before[result.id] = Set(model.tracks?.subtitles.map(\.id) ?? [])
        downloads[result.id] = .requesting
        requestedBazarr.append(result)
        downloadTask = Task { [weak self] in
            do {
                try await client.download(result, for: target)
            } catch {
                guard !Task.isCancelled else { return }
                Haptics.error()
                self?.downloads[result.id] = .failed(error as? BazarrError ?? .unreachable)
                return
            }
            self?.downloads[result.id] = .waiting(afterBazarr: true)
            await self?.waitForPlex(result)
        }
    }

    /// Asks Plex to look at the item again; never downloads again.
    func checkPlexAgain(_ result: BazarrSubtitle) {
        guard downloads[result.id]?.canCheckPlex == true, !isDownloading else { return }
        downloads[result.id] = .waiting(afterBazarr: false)
        downloadTask = Task { [weak self] in await self?.waitForPlex(result) }
    }

    /// Plex finds a new file next to the video only when it reads the item's files again, which takes a
    /// few seconds after the refresh is asked for.
    private func waitForPlex(_ result: BazarrSubtitle) async {
        guard let model else { return }
        do {
            try await model.library.refresh(ratingKey)
        } catch {
            guard !Task.isCancelled else { return }
            downloads[result.id] = .checkFailed
            return
        }
        let before = self.before[result.id] ?? []
        await show { $0.arrived(result.trackLanguage, kind: result.kind, since: before) } report: {
            downloads[result.id] = $0
        }
    }

    // MARK: Plex


    /// Search without discarding outcomes from earlier requests.
    func searchPlex(in language: TrackLanguage) {
        guard !plexAddUnresolved, let model, let code = language.code else { return }
        plexSearchTask?.cancel()
        plexSearch = .searching
        let key = ratingKey
        plexSearchTask = Task { [weak self] in
            let outcome: PlexSearch
            do {
                outcome = .found(try await model.library.searchSubtitles(key, language: code))
            } catch {
                outcome = .failed(unreachable: Self.isUnreachable(error))
            }
            guard !Task.isCancelled else { return }
            self?.plexSearch = outcome
        }
    }

    /// Plex issues fresh keys for each search; compare its identifying fields as well.
    func plexAttempt(for candidate: PlexSubtitleCandidate) -> Download? {
        if let exact = plexDownloads[candidate.id] { return exact }
        guard let title = candidate.title, !title.isEmpty,
              let provider = candidate.provider, !provider.isEmpty,
              let previous = requestedPlex.first(where: {
                  $0.title == title && $0.provider == provider && $0.language.matches(candidate.language)
              }) else { return nil }
        return plexDownloads[previous.id]
    }

    func canAdd(_ candidate: PlexSubtitleCandidate) -> Bool {
        plexAttempt(for: candidate) == nil && !isDownloading && !plexAddUnresolved && model?.tracks?.listed(candidate) == nil
    }

    func add(_ candidate: PlexSubtitleCandidate) {
        guard canAdd(candidate), let model else { return }
        plexBefore[candidate.id] = Set(model.tracks?.subtitles.map(\.id) ?? [])
        plexDownloads[candidate.id] = .requesting
        requestedPlex.append(candidate)
        let key = ratingKey
        downloadTask = Task { [weak self] in
            do {
                try await model.library.addSubtitle(key, candidate: candidate)
            } catch {
                guard !Task.isCancelled else { return }
                Haptics.error()
                self?.plexDownloads[candidate.id] = .notAdded(unreachable: Self.isUnreachable(error))
                return
            }
            self?.plexDownloads[candidate.id] = .waiting(afterBazarr: false)
            await self?.waitForPlex(candidate)
        }
    }

    /// Reads the item again; never adds the file again.
    func checkPlexAgain(_ candidate: PlexSubtitleCandidate) {
        guard plexDownloads[candidate.id]?.canCheckPlex == true, !isDownloading else { return }
        setAside.remove(candidate.id)
        plexDownloads[candidate.id] = .waiting(afterBazarr: false)
        downloadTask = Task { [weak self] in await self?.waitForPlex(candidate) }
    }

    /// Plex answers an add at once and lists the file a little later, under a new id and the release name.
    private func waitForPlex(_ candidate: PlexSubtitleCandidate) async {
        let before = plexBefore[candidate.id] ?? []
        await show { $0.landed(candidate, since: before) } report: {
            plexDownloads[candidate.id] = $0
        }
    }

    // MARK: Showing a download

    /// Reads the item until `find` picks the downloaded file out of it, then shows that file.
    private func show(_ find: (MediaTracks) -> SubtitleTrack?, report: (Download) -> Void) async {
        guard let model else { return }
        for wait in Self.plexWaits {
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            let tracks: MediaTracks?
            do {
                tracks = try await model.reloadTracks()
            } catch {
                guard !Task.isCancelled else { return }
                report(.checkFailed)
                return
            }
            guard let tracks else { break }
            if let track = find(tracks) {
                report(.loading(track: track.id))
                let shows = await model.show(track)
                if shows { Haptics.success() } else { Haptics.error() }
                report(shows ? .listed(track: track.id) : .playerFailed(track: track.id))
                return
            }
        }
        report(.notVisible)
    }

    private static func isUnreachable(_ error: any Error) -> Bool {
        switch error as? PlexError {
        case .unreachable?, .noConnections?: true
        default: false
        }
    }
}
