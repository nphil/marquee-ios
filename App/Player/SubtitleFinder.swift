import MarqueeCore
import Observation

/// Find Subtitles for the playing item (DESIGN §8.6): one action, with no source or file to choose.
/// Bazarr goes first and the server's own agents step in when it gives nothing (`SubtitleSearch`); the
/// status says which source is being asked and how the search ended. It lasts the item, so asking again
/// brings another file.
@MainActor @Observable
final class SubtitleFinder {
    struct Status: Equatable {
        enum Tone {
            case busy
            case found
            case missing
        }

        var tone: Tone
        var title: String
        var detail: String
    }

    /// The search's progress, then how it ended; nil before the item's first search.
    private(set) var status: Status?

    var isSearching: Bool { status?.tone == .busy }

    @ObservationIgnored private var ratingKey: String?
    /// Bazarr's movie or episode, found by the item's first search.
    @ObservationIgnored private var target: BazarrTarget?
    @ObservationIgnored private var tried = SubtitleSearch.Tried()
    /// A file a source took that the server had not listed when its search ended; the next search looks
    /// for it first.
    @ObservationIgnored private var unlisted: Unlisted?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Seconds between reads of the item while the server lists a new file: 19 s in all.
    private static let waits: [Double] = [1, 2, 3, 5, 8]

    func find(in model: PlayerModel) {
        guard !isSearching, model.tracks != nil else { return }
        itemChanged(to: model.item.ratingKey)
        let words = Words(language: model.subtitleLanguage)
        status = words.busy(unlisted != nil ? Words.checking : model.bazarr != nil ? Words.askingBazarr : Words.askingPlex)
        task = Task { await self.run(model, words: words) }
    }

    /// Another item plays: its search starts afresh.
    func itemChanged(to ratingKey: String) {
        guard ratingKey != self.ratingKey else { return }
        cancel()
        self.ratingKey = ratingKey
        target = nil
        tried = SubtitleSearch.Tried()
        unlisted = nil
        status = nil
    }

    func cancel() {
        task?.cancel()
        task = nil
        if isSearching { status = nil }
    }

    private func run(_ model: PlayerModel, words: Words) async {
        if let file = unlisted {
            unlisted = nil
            guard await listing(file, model, words: words, waits: [0]) == .notYet else { return }
        }
        let before = Set(model.tracks?.subtitles.map(\.id) ?? [])
        let search = SubtitleSearch(bazarr: model.bazarr, library: model.library, ratingKey: model.item.ratingKey, language: words.language)
        let outcome = await search.run(
            lookup: { await model.bazarrLookup() }, target: target, tracks: model.tracks, tried: tried
        ) { step in
            await self.say(words.status(for: step))
        }
        guard !Task.isCancelled else { return }
        target = outcome.target
        guard let added = outcome.added else {
            Haptics.error()
            status = words.nothing(outcome)
            return
        }
        tried.insert(added)
        status = words.busy(Words.waiting)
        guard await listing(Unlisted(added: added, before: before), model, words: words, waits: Self.waits) == .notYet else { return }
        Haptics.error()
        status = words.notListed(added.source)
    }

    private func say(_ status: Status) {
        guard !Task.isCancelled else { return }
        self.status = status
    }

    private enum Listing {
        /// On screen, or the player could not show it; the status says which.
        case shown
        case notYet
        /// The server could not be asked; the status says so.
        case failed
        /// Another item or file plays.
        case gone
    }

    /// Reads the item until the server lists `file`, then puts it on screen. The server lists a Bazarr
    /// download only once it reads the item's files again, so that is asked for first. A file still
    /// unlisted is kept in `unlisted`.
    private func listing(_ file: Unlisted, _ model: PlayerModel, words: Words, waits: [Double]) async -> Listing {
        var file = file
        if case .bazarr = file.added, !file.refreshed {
            do {
                try await model.library.refresh(model.item.ratingKey)
                file.refreshed = true
            } catch {
                return uncheckable(file)
            }
        }
        for wait in waits {
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return .gone }
            let tracks: MediaTracks?
            do {
                tracks = try await model.reloadTracks()
            } catch {
                return uncheckable(file)
            }
            guard let tracks, !Task.isCancelled else { return .gone }
            if let track = file.added.track(in: tracks, since: file.before) {
                let shows = await model.show(track)
                guard !Task.isCancelled else { return .gone }
                if shows { Haptics.success() } else { Haptics.error() }
                status = shows ? words.found(file.added) : words.notShown(problem: model.subtitleProblem)
                return .shown
            }
        }
        unlisted = file
        return .notYet
    }

    private func uncheckable(_ file: Unlisted) -> Listing {
        guard !Task.isCancelled else { return .gone }
        unlisted = file
        Haptics.error()
        status = Status(tone: .missing, title: "Couldn't check Plex", detail: "\(file.added.source.rawValue) sent a file. Find again to look for it.")
        return .failed
    }
}

private struct Unlisted {
    var added: SubtitleSearch.Added
    /// The subtitle ids the item listed before the file was asked for.
    var before: Set<Int>
    var refreshed = false
}

/// The status in words, for one language.
private struct Words: Sendable {
    static let askingBazarr = "Asking Bazarr…"
    static let askingPlex = "Asking Plex…"
    static let waiting = "Waiting for Plex to list it…"
    static let checking = "Checking Plex for the last file…"

    let language: TrackLanguage
    let name: String

    init(language: TrackLanguage) {
        self.language = language
        name = language.name ?? "English"
    }

    func busy(_ detail: String) -> SubtitleFinder.Status {
        .init(tone: .busy, title: "Finding \(name) subtitles", detail: detail)
    }

    func status(for step: SubtitleSearch.Step) -> SubtitleFinder.Status {
        switch step {
        case .searching(.bazarr, _): busy(Self.askingBazarr)
        case .searching(.plex, let miss): busy(miss.map { "\(reason($0)). \(Self.askingPlex)" } ?? Self.askingPlex)
        case .downloading(.bazarr): busy("Downloading from Bazarr…")
        case .downloading(.plex): busy("Adding from Plex…")
        }
    }

    func found(_ added: SubtitleSearch.Added) -> SubtitleFinder.Status {
        let provider: String? = switch added {
        case .bazarr(let subtitle): subtitle.providerName
        case .plex(let candidate): candidate.provider
        }
        let detail = ["From \(added.source.rawValue)", provider].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return .init(tone: .found, title: "\(name) subtitles on", detail: detail)
    }

    func nothing(_ outcome: SubtitleSearch.Outcome) -> SubtitleFinder.Status {
        let plex = outcome.plexFailed ? "Plex's search failed." : "Plex has nothing new."
        let detail = outcome.bazarrMiss.map { "\(reason($0)). \(plex)" } ?? plex
        return .init(tone: .missing, title: "No \(name) subtitles found", detail: detail)
    }

    func notListed(_ source: SubtitleSearch.Source) -> SubtitleFinder.Status {
        .init(tone: .missing, title: "Plex hasn't listed the new file yet", detail: "From \(source.rawValue). Find again to check.")
    }

    func notShown(problem: String?) -> SubtitleFinder.Status {
        .init(tone: .missing, title: "The new subtitles didn't load", detail: problem ?? "Find again for another file.")
    }

    private func reason(_ miss: SubtitleSearch.BazarrMiss) -> String {
        switch miss {
        case .slow: "Bazarr took too long"
        case .unreachable: "Bazarr can't be reached"
        case .refused: "Bazarr's address or key is wrong"
        case .unknownTitle: "Bazarr doesn't list this title"
        case .nothing: "Bazarr found nothing in \(name)"
        case .failed: "Bazarr's search failed"
        }
    }
}
