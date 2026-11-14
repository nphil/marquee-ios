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

    /// Home rows: Continue Watching (style `hero`), On Deck, Recently Added. Continue Watching is read
    /// from `/hubs/continueWatching`: Plex Web reads it from a hub of its own and asks `/hubs/promoted`
    /// with `excludeContinueWatching=1`. A server without that hub leaves the one in `/hubs/promoted`.
    public func promotedHubs(count: Int = 12) async throws -> [PlexHub] {
        async let promoted = container("/hubs/promoted", ["count": String(count)]).hubs
        let continuing = try? await container("/hubs/continueWatching", ["count": String(count)]).hubs
        return Self.settingContinueWatching(continuing, in: try await promoted)
    }

    /// `promoted` with its Continue Watching hub swapped for `continuing`, the answer of
    /// `/hubs/continueWatching`. Nil, or a hub that came without its items, keeps `promoted` as it is.
    static func settingContinueWatching(_ continuing: [PlexHub]?, in promoted: [PlexHub]) -> [PlexHub] {
        guard let continuing, continuing.allSatisfy({ $0.size == 0 || !$0.items.isEmpty }) else { return promoted }
        var hubs = promoted
        let at = hubs.firstIndex { $0.style == "hero" || $0.identifier == "home.continue" }
        if let at { hubs.remove(at: at) }
        guard var hub = continuing.first(where: { !$0.items.isEmpty }) else { return hubs }
        hub.identifier = "home.continue"
        hub.style = "hero"
        hubs.insert(hub, at: at ?? 0)
        return hubs
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

    /// Completed DVR versions in the libraries the DVR records into (`sectionIDs`, from the rules' target
    /// library). Plex marks a finished recording on its `Media` with `origin="dvr"` and
    /// `mediaGrabStatus="complete"`; there is no server-side filter on those, so each library is read
    /// through and filtered here.
    public func recordedItems(inSections sectionIDs: Set<Int>) async throws -> [PlexMetadata] {
        guard !sectionIDs.isEmpty else { return [] }
        var recordings: [PlexMetadata] = []
        for section in try await sections() where Int(section.key).map(sectionIDs.contains) == true {
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

    /// Takes an item off Continue Watching and leaves its watched state and resume point alone. The key is
    /// the card's own, an episode's or a film's, never its show's: Plex Web sends `PUT
    /// /actions/removeFromContinueWatching?ratingKey=` with the item's key whether it is part-watched or
    /// the next episode up, and python-plexapi offers the call on `Movie` and `Episode` only.
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

    /// The HLS URL of a server transcode, on the address that answered its decision. The decision is asked
    /// first with the same parameters and session, as Plex's own apps do: without one, PMS 1.43.5 refused
    /// the `start.m3u8` of a player's later sessions ("session lacking decision", 2026-11-11). The URL
    /// carries the client identity too, since the server picks the output formats by platform and the
    /// player cannot send headers.
    public func transcodeURL(_ request: TranscodeRequest) async throws -> URL {
        let (_, address) = try await exchange(isRead: true) { address in
            try self.request(
                .get, "/video/:/transcode/universal/decision", request.queryItems(location: Self.location(of: address)),
                [:], nil, nil, base: address.uri
            )
        }
        let identity = http.identity.headers(token: nil)
            .filter { $0.key.hasPrefix("X-Plex-") }
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        var query = request.queryItems(location: Self.location(of: address)) + identity
        if let token = server.accessToken { query.append(URLQueryItem(name: PlexHeader.token, value: token)) }
        guard let url = PlexURL.make(base: address.uri, path: "/video/:/transcode/universal/start.m3u8", query: query) else {
            throw PlexError.decoding("bad path")
        }
        return url
    }

    /// What the server would make for a transcode, without starting it: `Metadata[0].Media[0]`
    /// describes the output, its video stream's `bitrate` the encoder's rate. A downloaded conversion
    /// keeps the last one as its description.
    public func transcodeDecision(_ request: TranscodeRequest) async throws -> PlexMetadataSnapshot {
        let (response, _) = try await exchange(isRead: true) { address in
            try self.request(
                .get, "/video/:/transcode/universal/decision", request.queryItems(location: Self.location(of: address)),
                [:], nil, nil, base: address.uri
            )
        }
        return PlexMetadataSnapshot(item: try PlexMetadata.fromSnapshot(response.body), data: response.body)
    }

    private static func location(of address: PlexConnection) -> String {
        address.isLocal ? "lan" : "wan"
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

    /// Sends through the chosen address. `PlexLiveTV` sends through here too.
    func send(
        _ method: HTTPMethod,
        _ path: String,
        _ query: [URLQueryItem],
        headers: [String: String],
        idempotent: Bool? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> PlexHTTPResponse {
        try await exchange(isRead: idempotent ?? (method == .get)) { address in
            try request(method, path, query, headers, idempotent, timeout, base: address.uri)
        }.response
    }

    /// Sends the request `make` builds for the chosen address. When that address gives no answer, it is
    /// dropped; a read is repeated once if probing finds a different one. Returns the answer and the
    /// address that gave it.
    private func exchange(
        isRead: Bool,
        _ make: (PlexConnection) throws -> PlexRequest
    ) async throws -> (response: PlexHTTPResponse, address: PlexConnection) {
        let first = try await connection.connection()
        do {
            return (try await http.send(make(first)), first)
        } catch PlexError.unreachable(let failure) {
            await connection.reportFailure(of: first)
            guard isRead, let next = try? await connection.connection(), next != first else {
                throw PlexError.unreachable(failure)
            }
            return (try await http.send(make(next)), next)
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
