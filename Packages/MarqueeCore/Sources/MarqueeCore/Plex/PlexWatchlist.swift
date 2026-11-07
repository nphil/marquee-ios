import Foundation

/// The profile's watchlist, kept by plex.tv's discover service. Entries are catalogue titles keyed by the
/// last part of their `plex://` guid; a server item with the same guid is the same title.
public struct PlexWatchlist: Sendable {
    public static let base = URL(string: "https://discover.provider.plex.tv")!
    /// Carries the account token of the current profile.
    public let http: PlexHTTPClient

    public init(http: PlexHTTPClient) {
        self.http = http
    }

    /// One page of the watchlist, most recently added first.
    public func items(start: Int, size: Int = 60) async throws -> PlexPage<PlexMetadata> {
        var request = request(.get, "/library/sections/watchlist/all", ["includeCollections": "1", "includeExternalMedia": "1"])
        request.headers[PlexHeader.containerStart] = String(start)
        request.headers[PlexHeader.containerSize] = String(size)
        let result = try await http.decode(PlexEnvelope.self, from: request).container
        return PlexPage(items: result.metadata, totalSize: result.totalSize ?? start + result.metadata.count)
    }

    /// Whether the title with this guid is on the watchlist.
    public func contains(guid: String) async throws -> Bool {
        guard let key = Self.catalogueKey(guid: guid) else { return false }
        let states = try await http.decode(UserStates.self, from: request(.get, "/library/metadata/\(key)/userState"))
        return states.items.contains { $0.watchlistedAt != nil }
    }

    public func add(guid: String) async throws {
        try await change("/actions/addToWatchlist", guid: guid)
    }

    public func remove(guid: String) async throws {
        try await change("/actions/removeFromWatchlist", guid: guid)
    }

    /// The catalogue key of a `plex://movie/5d776b59ad5437001f79c6f8` guid. Titles matched by an older agent
    /// (`com.plexapp.agents.imdb://…`) have none and cannot be watchlisted.
    public static func catalogueKey(guid: String?) -> String? {
        guard let guid, guid.hasPrefix("plex://"), let key = guid.split(separator: "/").last, !key.isEmpty else { return nil }
        return String(key)
    }

    private func change(_ path: String, guid: String) async throws {
        guard let key = Self.catalogueKey(guid: guid) else { throw PlexError.decoding("not a catalogue title") }
        _ = try await http.send(request(.put, path, ["ratingKey": key]))
    }

    private func request(_ method: HTTPMethod, _ path: String, _ query: [String: String] = [:]) -> PlexRequest {
        let items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return PlexRequest(method: method, url: PlexURL.make(base: Self.base, path: path, query: items)!)
    }
}

/// `{"MediaContainer": {"UserState": [{"ratingKey": …, "watchlistedAt": …}]}}`.
private struct UserStates: Decodable {
    struct State: Decodable {
        let watchlistedAt: Date?

        enum CodingKeys: String, CodingKey { case watchlistedAt }

        init(from decoder: any Decoder) throws {
            watchlistedAt = try decoder.container(keyedBy: CodingKeys.self).date(.watchlistedAt)
        }
    }

    let items: [State]

    enum Outer: String, CodingKey { case container = "MediaContainer" }
    enum Inner: String, CodingKey { case states = "UserState" }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Outer.self).nestedContainer(keyedBy: Inner.self, forKey: .container)
        if let one = try? container.decode(State.self, forKey: .states) {
            items = [one]
        } else {
            items = container.list(.states)
        }
    }
}
