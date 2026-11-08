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

    /// What the server's subtitle agents (OpenSubtitles and the like) find for an item in one language,
    /// best match first. `language` is a two-letter code: the server fails on a three-letter one. Full
    /// subtitles only, neither forced nor for the deaf, as the server offers by default.
    public func searchSubtitles(_ ratingKey: String, language: String) async throws -> [PlexSubtitleCandidate] {
        let query = [
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "hearingImpaired", value: "0"),
            URLQueryItem(name: "forced", value: "0"),
        ]
        let response = try await send(.get, "/library/metadata/\(ratingKey)/subtitles", query, headers: [:])
        let rows = try PlexJSON.decode(CandidateEnvelope.self, from: response.body).rows
        return rows.compactMap(PlexSubtitleCandidate.init).enumerated()
            .sorted { ($0.element.score ?? .min, -$0.offset) > ($1.element.score ?? .min, -$1.offset) }
            .map(\.element)
    }

    /// Asks the server to download a candidate next to the video. It answers at once and lists the file a
    /// little later, as a new stream it also selects.
    public func addSubtitle(_ ratingKey: String, candidate: PlexSubtitleCandidate) async throws {
        let query = [URLQueryItem(name: "key", value: candidate.key)]
        _ = try await send(.put, "/library/metadata/\(ratingKey)/subtitles", query, headers: [:], idempotent: false)
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

/// A subtitle the server's agents offer for an item. Its key is good only for the search that found it:
/// a later search names the same file anew, and an old key downloads nothing.
public struct PlexSubtitleCandidate: Sendable, Hashable, Identifiable {
    public var id: String { key }
    public var key: String
    /// The provider's release name, which the file keeps once it is added.
    public var title: String?
    public var language: TrackLanguage
    public var provider: String?
    /// The agent's match score, on the provider's own scale; higher is closer.
    public var score: Int?

    public init(key: String, title: String?, language: TrackLanguage, provider: String?, score: Int?) {
        self.key = key
        self.title = title
        self.language = language
        self.provider = provider
        self.score = score
    }

    init?(_ row: CandidateEnvelope.Row) {
        guard let key = row.stream.key, row.stream.kind == .subtitle else { return nil }
        self.init(
            key: key, title: row.stream.title, language: TrackLanguage(stream: row.stream),
            provider: row.provider, score: row.score
        )
    }
}

struct CandidateEnvelope: Decodable {
    let rows: [Row]

    /// An ordinary subtitle stream plus the provider's fields; the score comes as text.
    struct Row: Decodable {
        let stream: PlexStream
        let provider: String?
        let score: Int?

        enum CodingKeys: String, CodingKey { case provider = "providerTitle", score }

        init(from decoder: any Decoder) throws {
            stream = try PlexStream(from: decoder)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            provider = c.string(.provider)
            score = c.int(.score)
        }
    }

    private struct Container: Decodable {
        let rows: [Row]

        enum CodingKeys: String, CodingKey { case rows = "Stream" }

        init(from decoder: any Decoder) throws {
            rows = decoder.lenientList(CodingKeys.rows)
        }
    }

    enum CodingKeys: String, CodingKey { case container = "MediaContainer" }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rows = try c.decode(Container.self, forKey: .container).rows
    }
}

private extension Decoder {
    func lenientList<Key: CodingKey, T: Decodable>(_ key: Key) -> [T] {
        guard let c = try? container(keyedBy: Key.self) else { return [] }
        return c.list(key)
    }
}
