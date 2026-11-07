import Foundation

extension PlexLibrary {
    /// Deletes a subtitle file the server lists as a separate stream. Embedded tracks cannot be removed.
    public func removeSubtitle(streamID: Int) async throws {
        _ = try await send(.delete, "/library/streams/\(streamID)", [], headers: [:], idempotent: false)
    }

    /// Asks the server to look at the item again, which finds subtitle files added next to its video.
    public func refresh(_ ratingKey: String) async throws {
        _ = try await send(.put, "/library/metadata/\(ratingKey)/refresh", [], headers: [:], idempotent: false)
    }

    /// The item's ids at IMDb, TMDB and TVDB, as `imdb://tt0133093`.
    public func externalIDs(_ ratingKey: String) async throws -> [String] {
        let query = [URLQueryItem(name: "includeGuids", value: "1")]
        let response = try await send(.get, "/library/metadata/\(ratingKey)", query, headers: [:])
        return try PlexJSON.decode(GuidEnvelope.self, from: response.body).ids
    }
}

private struct GuidEnvelope: Decodable {
    let ids: [String]

    private struct Container: Decodable {
        let metadata: [Item]

        enum CodingKeys: String, CodingKey { case metadata = "Metadata" }

        init(from decoder: any Decoder) throws {
            metadata = decoder.lenientList(CodingKeys.metadata)
        }
    }

    private struct Item: Decodable {
        let guids: [Guid]

        enum CodingKeys: String, CodingKey { case guids = "Guid" }

        init(from decoder: any Decoder) throws {
            guids = decoder.lenientList(CodingKeys.guids)
        }
    }

    private struct Guid: Decodable {
        let id: String
    }

    enum CodingKeys: String, CodingKey { case container = "MediaContainer" }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let container = try c.decode(Container.self, forKey: .container)
        ids = container.metadata.first?.guids.map(\.id) ?? []
    }
}

private extension Decoder {
    func lenientList<Key: CodingKey, T: Decodable>(_ key: Key) -> [T] {
        guard let c = try? container(keyedBy: Key.self) else { return [] }
        return c.list(key)
    }
}
