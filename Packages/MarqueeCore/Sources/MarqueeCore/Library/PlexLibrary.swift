import Foundation

/// The library API of one server, reached through its chosen address with this user's server token.
public struct PlexLibrary: Sendable {
    public let connection: PlexServerConnection
    let http: PlexHTTPClient

    public var server: PlexServer { connection.server }

    public init(
        server: PlexServer,
        identity: PlexClientIdentity,
        transport: any PlexTransport = URLSessionTransport(),
        rememberedURI: URL? = nil
    ) {
        connection = PlexServerConnection(server: server, identity: identity, transport: transport, remembered: rememberedURI)
        http = PlexHTTPClient(identity: identity, token: server.accessToken, transport: transport)
    }

    // MARK: Browsing

    /// Home rows: Continue Watching (style `hero`), On Deck, Recently Added.
    public func promotedHubs(count: Int = 12) async throws -> [PlexHub] {
        try await container("/hubs/promoted", ["count": String(count)]).hubs
    }

    public func sections() async throws -> [PlexLibrarySection] {
        try await container("/library/sections").directories.map(PlexLibrarySection.init)
    }

    /// One page of a library grid, `size` items from `start`.
    public func items(in sectionKey: String, query: SectionQuery, start: Int, size: Int = 60) async throws -> PlexPage<PlexMetadata> {
        let paging = [PlexHeader.containerStart: String(start), PlexHeader.containerSize: String(size)]
        let result = try await container("/library/sections/\(sectionKey)/all", query.queryItems, headers: paging)
        return PlexPage(items: result.metadata, totalSize: result.totalSize ?? start + result.metadata.count)
    }

    /// Completed DVR versions across all movie and TV libraries, including libraries without an active rule.
    public func recordedItems() async throws -> [PlexMetadata] {
        var recordings: [PlexMetadata] = []
        for section in try await sections() {
            let type: PlexMediaType
            switch section.type {
            case .movie: type = .movie
            case .show: type = .episode
            default: continue
            }
            let query = SectionQuery(type: type).queryItems
            var start = 0
            while true {
                try Task.checkCancellation()
                let headers = [PlexHeader.containerStart: String(start), PlexHeader.containerSize: "200"]
                let page = try await container("/library/sections/\(section.key)/all", query, headers: headers)
                guard !page.metadata.isEmpty else { break }
                recordings.append(contentsOf: page.metadata.filter(\.isDVRRecording))
                start += page.metadata.count
                if let total = page.totalSize, start >= total { break }
            }
        }
        return recordings.sorted {
            let left = $0.recordedAt ?? .distantPast
            let right = $1.recordedAt ?? .distantPast
            return left == right ? $0.ratingKey < $1.ratingKey : left > right
        }
    }

    /// The A–Z jump bar for a grid with the same query.
    public func alphabetIndex(in sectionKey: String, query: SectionQuery) async throws -> [AlphabetIndexEntry] {
        let result = try await container("/library/sections/\(sectionKey)/firstCharacter", query.queryItems)
        return AlphabetIndexEntry.entries(from: result.directories)
    }

    /// The genres of a library's titles, for the grid filter.
    public func genres(in sectionKey: String) async throws -> [PlexDirectory] {
        try await container("/library/sections/\(sectionKey)/genre").directories
    }

    /// One page of a library's collections.
    public func collections(in sectionKey: String, start: Int, size: Int = 60) async throws -> PlexPage<PlexMetadata> {
        try await list("/library/sections/\(sectionKey)/collections", start: start, size: size)
    }

    /// The Recommended rows of one library.
    public func recommendedHubs(in sectionKey: String, count: Int = 12) async throws -> [PlexHub] {
        try await container("/hubs/sections/\(sectionKey)", ["count": String(count)]).hubs
    }

    /// One page of the list behind a key the server handed out: a row's "see all", a collection's titles,
    /// a person's titles. The key may carry a query of its own.
    public func list(_ key: String, start: Int, size: Int = 60) async throws -> PlexPage<PlexMetadata> {
        let (path, query) = Self.split(key)
        let paging = [PlexHeader.containerStart: String(start), PlexHeader.containerSize: String(size)]
        let result = try await container(path, query, headers: paging)
        return PlexPage(items: result.metadata, totalSize: result.totalSize ?? start + result.metadata.count)
    }

    /// Everything a person appears in across every library, by the person's tag `id` (`PlexRole.id`).
    public func titles(ofPerson id: String) async throws -> [PlexMetadata] {
        try await container("/library/people/\(id)/media").metadata
    }

    /// A movie's or show's bonus videos (trailers, featurettes, deleted scenes) as `clip` rows that play
    /// like any title.
    public func extras(of ratingKey: String) async throws -> [PlexMetadata] {
        try await container("/library/metadata/\(ratingKey)/extras").metadata
    }

    /// Titles like `ratingKey`, as rows.
    public func related(to ratingKey: String) async throws -> [PlexHub] {
        try await container("/library/metadata/\(ratingKey)/related").hubs
    }

    /// This server's copies of a catalogue title, found by its `plex://` guid, e.g. for a watchlist entry.
    public func items(matchingGuid guid: String) async throws -> [PlexMetadata] {
        try await container("/library/all", ["guid": guid]).metadata
    }

    /// Full details of an item, with its streams, markers and chapters, and for a show the episode to
    /// play next.
    public func metadata(_ ratingKey: String) async throws -> PlexMetadata {
        let query = ["includeMarkers": "1", "includeChapters": "1", "includeOnDeck": "1"]
        guard let item = try await container("/library/metadata/\(ratingKey)", query).metadata.first else {
            throw PlexError.server(status: 404, message: nil)
        }
        return item
    }

    /// Every episode of a show, across its seasons.
    public func allLeaves(of ratingKey: String) async throws -> [PlexMetadata] {
        try await container("/library/metadata/\(ratingKey)/allLeaves").metadata
    }

    /// Seasons of a show or episodes of a season.
    public func children(of ratingKey: String) async throws -> [PlexMetadata] {
        try await container("/library/metadata/\(ratingKey)/children").metadata
    }

    /// Search results grouped by kind: movies, shows, episodes, people.
    public func search(_ text: String, limit: Int = 10) async throws -> [PlexHub] {
        try await container("/hubs/search", ["query": text, "limit": String(limit)]).hubs
    }

    /// What the server's owner allows and pays for, from the server's root.
    public func serverInfo() async throws -> PlexServerInfo {
        let root = try await container("/")
        return PlexServerInfo(allowsMediaDeletion: root.allowMediaDeletion, hasPlexPass: root.myPlexSubscription)
    }

    // MARK: Watch state

    public func markWatched(_ ratingKey: String) async throws {
        try await perform(.get, "/:/scrobble", ["identifier": "com.plexapp.plugins.library", "key": ratingKey])
    }

    public func markUnwatched(_ ratingKey: String) async throws {
        try await perform(.get, "/:/unscrobble", ["identifier": "com.plexapp.plugins.library", "key": ratingKey])
    }

    /// Takes an item off Continue Watching and leaves its watched state and resume point alone.
    public func removeFromContinueWatching(_ ratingKey: String) async throws {
        try await perform(.put, "/actions/removeFromContinueWatching", ["ratingKey": ratingKey])
    }

    public func reportTimeline(_ update: TimelineUpdate) async throws {
        var headers: [String: String] = [:]
        if let session = update.sessionIdentifier { headers[PlexHeader.sessionIdentifier] = session }
        try await perform(.get, "/:/timeline", update.queryItems, headers: headers)
    }

    // MARK: Deleting

    /// How long a delete may take: the server removes the files before it answers.
    static let deleteTimeout: TimeInterval = 180

    /// Deletes a movie, episode, season or show and its files from the server's disk. The server refuses
    /// (401 or 403) unless its owner turned on deleting media from the apps.
    public func delete(_ ratingKey: String) async -> DeleteOutcome {
        await deleting("/library/metadata/\(ratingKey)")
    }

    /// As `delete(_:)`, but throws what the server answered, for `MediaDeletion` to judge.
    public func deleteItem(_ ratingKey: String) async throws {
        try await perform(.delete, "/library/metadata/\(ratingKey)", [:], timeout: Self.deleteTimeout)
    }

    /// Deletes one version of a title and its file from the server's disk, leaving the others.
    public func deleteVersion(_ mediaID: Int, of ratingKey: String) async -> DeleteOutcome {
        await deleting("/library/metadata/\(ratingKey)/media/\(mediaID)")
    }

    private func deleting(_ path: String) async -> DeleteOutcome {
        do {
            try await perform(.delete, path, [:], timeout: Self.deleteTimeout)
            return .deleted
        } catch {
            return DeleteOutcome(error)
        }
    }

    // MARK: Playback

    /// A play queue starting at `item`. Episodes queue the rest of their show (`continuous=1`).
    public func createPlayQueue(for item: PlexMetadata) async throws -> PlexPlayQueue {
        let continuous = [.episode, .season, .show].contains(item.type)
        let uri = "server://\(server.clientIdentifier)/com.plexapp.plugins.library/library/metadata/\(item.ratingKey)"
        let query = [
            "type": "video",
            "uri": uri,
            "continuous": continuous ? "1" : "0",
            "shuffle": "0",
            "repeat": "0",
            "own": "1",
            "includeChapters": "1",
            "includeMarkers": "1",
        ]
        let result = try await container("/playQueues", query, method: .post)
        guard let queue = PlexPlayQueue(result) else { throw PlexError.decoding("play queue without an id") }
        return queue
    }

    public func playQueue(_ id: Int) async throws -> PlexPlayQueue {
        let result = try await container("/playQueues/\(id)", ["includeChapters": "1", "includeMarkers": "1"])
        guard let queue = PlexPlayQueue(result) else { throw PlexError.decoding("play queue without an id") }
        return queue
    }

    /// Saves the audio and subtitle choice for a part on the server (`subtitleStreamID` nil turns subtitles
    /// off), which a server transcode then uses.
    public func selectStreams(partID: Int, audioStreamID: Int?, subtitleStreamID: Int?) async throws {
        var query = ["allParts": "1", "subtitleStreamID": String(subtitleStreamID ?? 0)]
        if let audioStreamID { query["audioStreamID"] = String(audioStreamID) }
        try await perform(.put, "/library/parts/\(partID)", query)
    }

    /// The address and token for a URL the player fetches itself. The token is in the URL because
    /// AVPlayer cannot add headers; never log or cache these URLs.
    public func playbackURL(path: String, query: [URLQueryItem] = []) async throws -> URL {
        let base = try await connection.connection().uri
        var query = query
        if let token = server.accessToken { query.append(URLQueryItem(name: PlexHeader.token, value: token)) }
        guard let url = PlexURL.make(base: base, path: path, query: query) else { throw PlexError.decoding("bad path") }
        return url
    }

    /// The HLS URL of a server transcode. It carries the client identity too, since the server picks the
    /// output formats by platform and the player cannot send headers.
    public func transcodeURL(_ request: TranscodeRequest) async throws -> URL {
        let location = try await connection.connection().isLocal ? "lan" : "wan"
        let identity = http.identity.headers(token: nil)
            .filter { $0.key.hasPrefix("X-Plex-") }
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        let path = "/video/:/transcode/universal/start.m3u8"
        return try await playbackURL(path: path, query: request.queryItems(location: location) + identity)
    }

    /// Ends a server transcode session.
    public func stopTranscode(session: String) async throws {
        try await perform(.get, "/video/:/transcode/universal/stop", ["session": session])
    }

    /// A server-resized image URL for the current address. See `PlexImageURL`.
    public func imageURL(_ path: String, width: Double, height: Double, scale: Double) async throws -> URL? {
        let base = try await connection.connection().uri
        return PlexImageURL.transcoded(path, base: base, width: width, height: height, scale: scale)
    }

    /// The headers that authorize a request to this server, for loaders outside this client (images, the
    /// on-device remux).
    public func authorizationHeaders() -> [String: String] {
        http.identity.headers(token: server.accessToken)
    }

    // MARK: Transport

    private func container(
        _ path: String,
        _ query: [String: String] = [:],
        headers: [String: String] = [:],
        method: HTTPMethod = .get
    ) async throws -> PlexMediaContainer {
        try await container(path, Self.items(query), headers: headers, method: method)
    }

    private func container(
        _ path: String,
        _ query: [URLQueryItem],
        headers: [String: String] = [:],
        method: HTTPMethod = .get
    ) async throws -> PlexMediaContainer {
        let response = try await send(method, path, query, headers: headers)
        return try PlexJSON.decode(PlexEnvelope.self, from: response.body).container
    }

    private func perform(
        _ method: HTTPMethod,
        _ path: String,
        _ query: [String: String],
        headers: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) async throws {
        _ = try await send(method, path, Self.items(query), headers: headers, idempotent: false, timeout: timeout)
    }

    private func perform(_ method: HTTPMethod, _ path: String, _ query: [URLQueryItem], headers: [String: String]) async throws {
        _ = try await send(method, path, query, headers: headers, idempotent: false)
    }

    /// Sends through the chosen address. When it gives no answer, the address is dropped; a read is
    /// repeated once if probing finds a different one. `PlexLiveTV` sends through here too.
    func send(
        _ method: HTTPMethod,
        _ path: String,
        _ query: [URLQueryItem],
        headers: [String: String],
        idempotent: Bool? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> PlexHTTPResponse {
        let first = try await connection.connection()
        do {
            return try await http.send(request(method, path, query, headers, idempotent, timeout, base: first.uri))
        } catch PlexError.unreachable(let failure) {
            await connection.reportFailure(of: first)
            let isRead = idempotent ?? (method == .get)
            guard isRead, let next = try? await connection.connection(), next != first else {
                throw PlexError.unreachable(failure)
            }
            return try await http.send(request(method, path, query, headers, idempotent, timeout, base: next.uri))
        }
    }

    private func request(
        _ method: HTTPMethod,
        _ path: String,
        _ query: [URLQueryItem],
        _ headers: [String: String],
        _ idempotent: Bool?,
        _ timeout: TimeInterval?,
        base: URL
    ) throws -> PlexRequest {
        guard let url = PlexURL.make(base: base, path: path, query: query) else { throw PlexError.decoding("bad path") }
        var request = PlexRequest(method: method, url: url, headers: headers, isIdempotent: idempotent)
        if let timeout { request.timeout = timeout }
        return request
    }

    private static func items(_ query: [String: String]) -> [URLQueryItem] {
        query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    }

    /// `/hubs/home/recentlyAdded?type=1` as a path and its query items.
    static func split(_ key: String) -> (path: String, query: [URLQueryItem]) {
        guard let mark = key.firstIndex(of: "?") else { return (key, []) }
        let query = URLComponents(string: "?" + key[key.index(after: mark)...])?.queryItems ?? []
        return (String(key[..<mark]), query)
    }
}

/// What a server's owner allows and pays for.
public struct PlexServerInfo: Sendable, Hashable {
    /// Apps may delete media (the server's "Allow media deletion" setting).
    public var allowsMediaDeletion: Bool
    /// The owner has Plex Pass, which Boost dialog and Normalize loudness need.
    public var hasPlexPass: Bool

    public init(allowsMediaDeletion: Bool = false, hasPlexPass: Bool = false) {
        self.allowsMediaDeletion = allowsMediaDeletion
        self.hasPlexPass = hasPlexPass
    }
}
