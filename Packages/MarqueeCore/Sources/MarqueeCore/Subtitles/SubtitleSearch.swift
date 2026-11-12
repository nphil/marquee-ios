import Foundation

/// Finds subtitles for the playing item in one step, with no source or file to choose (behaviour spec
/// §3). Bazarr goes first, for at most `bazarrBudget`; the server's own agents, asked at the same time,
/// step in when Bazarr is not set up, cannot be reached, runs out of time or has nothing in the
/// language. Bazarr's providers took 15–18 s for an episode warm and 80–100 s cold (measured 2026-11),
/// so the budget bounds the wait, not the search.
public struct SubtitleSearch: Sendable {
    public enum Source: String, Sendable {
        case bazarr = "Bazarr"
        case plex = "Plex"
    }

    /// What the search is doing, for its status line.
    public enum Step: Sendable, Equatable {
        case searching(Source)
        case downloading(Source)
    }

    /// The file a source took. The server lists it a few seconds later.
    public enum Added: Sendable, Equatable {
        case bazarr(BazarrSubtitle)
        case plex(PlexSubtitleCandidate)

        public var source: Source {
            switch self {
            case .bazarr: .bazarr
            case .plex: .plex
            }
        }

        /// The track the file became, once `tracks` lists it; `before` holds the track ids listed before
        /// the file was asked for.
        public func track(in tracks: MediaTracks, since before: Set<Int>) -> SubtitleTrack? {
            switch self {
            case .bazarr(let subtitle): tracks.arrived(subtitle.trackLanguage, kind: subtitle.kind, since: before)
            case .plex(let candidate): tracks.landed(candidate, since: before)
            }
        }
    }

    /// Why Bazarr gave no file.
    public enum BazarrMiss: Sendable, Equatable {
        /// No answer within the budget, or a request timed out.
        case slow
        case unreachable
        /// The key was refused, or the address answers but not as Bazarr.
        case refused
        /// Neither Sonarr nor Radarr lists the title.
        case unknownTitle
        /// Nothing in the language.
        case nothing
        /// The search or the download failed.
        case failed
    }

    public struct Outcome: Sendable, Equatable {
        public var added: Added?
        /// Why Bazarr gave no file; nil when it gave one or is not set up.
        public var bazarrMiss: BazarrMiss?
        /// The server's agents could not be asked, or would not add their file.
        public var plexFailed: Bool
        /// Bazarr's movie or episode, to ask for directly next time.
        public var target: BazarrTarget?

        public init(added: Added? = nil, bazarrMiss: BazarrMiss? = nil, plexFailed: Bool = false, target: BazarrTarget? = nil) {
            self.added = added
            self.bazarrMiss = bazarrMiss
            self.plexFailed = plexFailed
            self.target = target
        }
    }

    /// The files earlier searches of an item added, so asking again brings another.
    public struct Tried: Sendable, Equatable {
        private var keys: Set<String> = []

        public init() {}

        public mutating func insert(_ added: Added) {
            keys.insert(Self.key(added))
        }

        func contains(_ added: Added) -> Bool {
            keys.contains(Self.key(added))
        }

        /// Bazarr's handle and the server's key change from one search to the next; the release does not.
        private static func key(_ added: Added) -> String {
            switch added {
            case .bazarr(let subtitle):
                let release = subtitle.releases.isEmpty ? subtitle.subtitle : subtitle.releases.joined(separator: "|")
                return ["bazarr", subtitle.provider, subtitle.isHearingImpaired ? "hi" : "", release].joined(separator: "/")
            case .plex(let candidate):
                return ["plex", candidate.provider ?? "", candidate.title ?? candidate.key].joined(separator: "/")
            }
        }
    }

    /// Within this many points of Bazarr's best match a regular file wins over one for the deaf; further
    /// behind, it is most often made for another release and runs out of sync.
    static let regularMargin = 10.0

    public var bazarr: BazarrClient?
    public var library: PlexLibrary
    public var ratingKey: String
    public var language: TrackLanguage
    public var bazarrBudget: Duration

    public init(
        bazarr: BazarrClient?, library: PlexLibrary, ratingKey: String, language: TrackLanguage, bazarrBudget: Duration = .seconds(20)
    ) {
        self.bazarr = bazarr
        self.library = library
        self.ratingKey = ratingKey
        self.language = language
        self.bazarrBudget = bazarrBudget
    }

    /// Searches, then has the first source with a file add it.
    ///
    /// - Parameters:
    ///   - lookup: What Bazarr is asked to find; read only when `target` is nil.
    ///   - target: Bazarr's movie or episode from an earlier search of the item.
    ///   - tracks: The item's tracks now, so a file the server lists already is not added again.
    ///   - tried: The files earlier searches of the item added.
    ///   - step: Told as each step starts.
    public func run(
        lookup: @escaping @Sendable () async -> BazarrLookup,
        target: BazarrTarget?,
        tracks: MediaTracks?,
        tried: Tried,
        step: @Sendable (Step) async -> Void
    ) async -> Outcome {
        async let plexOffers = plexSearch()
        var outcome = Outcome(target: target)
        if let bazarr {
            await step(.searching(.bazarr))
            let turn = await bazarrTurn(bazarr, lookup: lookup, target: target, tried: tried)
            outcome.target = turn.target ?? target
            if let subtitle = turn.pick, let found = outcome.target, !Task.isCancelled {
                await step(.downloading(.bazarr))
                do {
                    try await bazarr.download(subtitle, for: found)
                    outcome.added = .bazarr(subtitle)
                    return outcome
                } catch {
                    outcome.bazarrMiss = Self.miss(error)
                }
            } else {
                outcome.bazarrMiss = turn.miss
            }
        }
        await step(.searching(.plex))
        guard let offers = await plexOffers else {
            outcome.plexFailed = true
            return outcome
        }
        guard let candidate = offers.first(where: { !tried.contains(.plex($0)) && tracks?.listed($0) == nil }),
              !Task.isCancelled else { return outcome }
        await step(.downloading(.plex))
        do {
            try await library.addSubtitle(ratingKey, candidate: candidate)
            outcome.added = .plex(candidate)
        } catch {
            outcome.plexFailed = true
        }
        return outcome
    }

    /// Bazarr's file for the language: the best regular match (neither forced nor for the deaf) unless it
    /// trails the best match by more than `regularMargin`. Never a file already tried, nor WhisperAI's,
    /// which transcribes the audio and takes minutes to arrive.
    static func pick(_ offers: [BazarrSubtitle], in language: TrackLanguage, skipping tried: Tried) -> BazarrSubtitle? {
        let usable = offers.filter {
            $0.trackLanguage.matches(language) && !$0.isForced && $0.provider != "whisperai" && !tried.contains(.bazarr($0))
        }
        guard let best = usable.max(by: { $0.score < $1.score }) else { return nil }
        return usable.filter { !$0.isHearingImpaired && $0.score >= best.score - regularMargin }.max { $0.score < $1.score } ?? best
    }

    static func miss(_ error: any Error) -> BazarrMiss {
        switch error as? BazarrError {
        case .timedOut?: .slow
        case .unreachable?: .unreachable
        case .badKey?, .notBazarr?: .refused
        case .notFound?: .unknownTitle
        default: .failed
        }
    }

    private struct Turn: Sendable {
        var pick: BazarrSubtitle?
        var miss: BazarrMiss?
        var target: BazarrTarget?
    }

    /// Bazarr's search, given up at the budget.
    private func bazarrTurn(
        _ bazarr: BazarrClient, lookup: @escaping @Sendable () async -> BazarrLookup, target: BazarrTarget?, tried: Tried
    ) async -> Turn {
        let language = language, budget = bazarrBudget
        return await withTaskGroup(of: Turn?.self) { group in
            group.addTask {
                var found = target
                do {
                    if found == nil {
                        let lookup = await lookup()
                        found = try await bazarr.find(lookup)
                    }
                    guard let found else { return Turn(miss: .unknownTitle) }
                    let offers = try await bazarr.search(found)
                    guard let pick = Self.pick(offers, in: language, skipping: tried) else { return Turn(miss: .nothing, target: found) }
                    return Turn(pick: pick, target: found)
                } catch {
                    return Turn(miss: Self.miss(error), target: found)
                }
            }
            group.addTask {
                try? await Task.sleep(for: budget)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? Turn(miss: .slow)
        }
    }

    /// The agents' files in the language, best first; nil when the server could not be asked.
    private func plexSearch() async -> [PlexSubtitleCandidate]? {
        guard let code = language.code else { return [] }
        return try? await library.searchSubtitles(ratingKey, language: code)
    }
}
