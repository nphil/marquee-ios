import MarqueeCore
import Observation

/// "Wrong Subtitles?" for one item (DESIGN §8.6): removing the subtitle file on screen from Plex, and
/// finding another with Bazarr. It lasts as long as the item plays, so a search and its downloads are
/// where they were when the sheet opens again.
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

    /// Where one download stands. Bazarr reports no progress, so every state is a step the app saw
    /// happen.
    enum Download: Equatable {
        case requesting
        /// Plex is asked to read the item's files again: after Bazarr took the request, or for Check
        /// Plex Again.
        case waiting(afterBazarr: Bool)
        case notVisible
        case checkFailed
        case loading(track: Int)
        /// Plex lists the file as this track.
        case listed(track: Int)
        case playerFailed(track: Int)
        case failed(BazarrError)

        var isBusy: Bool {
            switch self {
            case .requesting, .waiting, .loading: true
            default: false
            }
        }

        /// Plex may hold the file already: a timed-out request can still have been carried out.
        var canCheckPlex: Bool {
            switch self {
            case .notVisible, .checkFailed, .failed(.timedOut): true
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
    /// The language results are listed in.
    var language: TrackLanguage
    private(set) var downloads: [BazarrSubtitle.ID: Download] = [:]

    @ObservationIgnored private weak var model: PlayerModel?
    @ObservationIgnored private var target: BazarrTarget?
    /// The track ids Plex listed before each download, so the file it adds can be told apart.
    @ObservationIgnored private var before: [BazarrSubtitle.ID: Set<Int>] = [:]
    @ObservationIgnored private var removeTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    /// Seconds between reads of the item while Plex finds a downloaded file: 19 s in all.
    private static let plexWaits: [Double] = [1, 2, 3, 5, 8]

    init(model: PlayerModel, language: TrackLanguage) {
        self.model = model
        ratingKey = model.item.ratingKey
        self.language = TrackLanguage(code: language.code)
    }

    /// The sheet opened again: an old removal's outcome is no longer news.
    func open() {
        if removal != .removing { removal = nil }
    }

    func cancel() {
        for task in [removeTask, searchTask, downloadTask] { task?.cancel() }
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
                let unreachable: Bool = switch error as? PlexError {
                case .unreachable?, .noConnections?: true
                default: false
                }
                self?.removal = unreachable ? .unreachable : .refused
                return
            }
            Haptics.success()
            guard let self else { return }
            removal = .removed
            // A downloaded file that was just removed is no longer in Plex; its result can be had again.
            downloads = downloads.filter { $0.value.track != track.id }
            await model.removed(track)
        }
    }

    // MARK: Search

    func searchIfNeeded() {
        if search == nil { searchAgain() }
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
                self?.target = target
                outcome = .found(try await client.search(target))
            } catch {
                outcome = .failed(error as? BazarrError ?? .unreachable)
            }
            guard !Task.isCancelled else { return }
            self?.search = outcome
        }
    }

    /// The languages results come in, the asked-for one first and the rest A to Z.
    var languages: [TrackLanguage] {
        guard case .found(let results) = search else { return [language] }
        let others = Set(results.compactMap { $0.trackLanguage.code }).subtracting([language.code].compactMap { $0 })
            .map { TrackLanguage(code: $0) }
            .sorted { ($0.name ?? "") < ($1.name ?? "") }
        return [language] + others
    }

    /// The results in the chosen language, best match first.
    var results: [BazarrSubtitle] {
        guard case .found(let results) = search else { return [] }
        return results.filter { $0.trackLanguage.matches(language) }
    }

    // MARK: Download

    /// One download at a time, and never one result twice.
    func canDownload(_ result: BazarrSubtitle) -> Bool {
        downloads[result.id] == nil && !downloads.values.contains(where: \.isBusy) && target != nil
    }

    func download(_ result: BazarrSubtitle) {
        guard canDownload(result), let model, let client = model.bazarr, let target else { return }
        before[result.id] = Set(model.tracks?.subtitles.map(\.id) ?? [])
        downloads[result.id] = .requesting
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
        guard downloads[result.id]?.canCheckPlex == true, !downloads.values.contains(where: \.isBusy) else { return }
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
        for wait in Self.plexWaits {
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            let tracks: MediaTracks?
            do {
                tracks = try await model.reloadTracks()
            } catch {
                guard !Task.isCancelled else { return }
                downloads[result.id] = .checkFailed
                return
            }
            guard let tracks else { break }
            if let track = tracks.arrived(result.trackLanguage, kind: result.kind, since: before[result.id] ?? []) {
                downloads[result.id] = .loading(track: track.id)
                let shows = await model.show(track)
                if shows { Haptics.success() } else { Haptics.error() }
                downloads[result.id] = shows ? .listed(track: track.id) : .playerFailed(track: track.id)
                return
            }
        }
        downloads[result.id] = .notVisible
    }
}
