import Foundation

/// One title in the server's download queue (PMS 1.41.2 and later): the server decides how to convert
/// it, converts it, then keeps the file for the app to fetch.
public struct PlexDownloadQueueItem: Sendable, Hashable, Decodable {
    public enum Status: String, Sendable, Hashable, Codable {
        case deciding, waiting, processing, available, error, expired, unknown
    }

    public var id: Int
    public var queueID: Int
    public var key: String
    public var status: Status
    /// The server's wording when the decision or the conversion failed.
    public var error: String?
    /// The share converted, 0…1, while the server converts.
    public var progress: Double?
    /// As a multiple of real time.
    public var speed: Double?

    enum CodingKeys: String, CodingKey {
        case id, queueId, key, status, error
        case session = "TranscodeSession"
    }

    enum SessionKeys: String, CodingKey { case progress, speed }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.int(.id) ?? 0
        queueID = c.int(.queueId) ?? 0
        key = c.string(.key) ?? ""
        status = c.string(.status).flatMap(Status.init(rawValue:)) ?? .unknown
        error = c.string(.error)
        let session = try? c.nestedContainer(keyedBy: SessionKeys.self, forKey: .session)
        progress = session?.double(.progress).map { min(max($0 / 100, 0), 1) }
        speed = session?.double(.speed)
    }
}

/// The server's answer for one title, kept as it came so a download can read it offline.
public struct PlexMetadataSnapshot: Sendable {
    public var item: PlexMetadata
    public var data: Data
}

extension PlexMetadata {
    /// The first title in a saved `PlexMetadataSnapshot`.
    public static func fromSnapshot(_ data: Data) throws -> PlexMetadata {
        guard let item = try PlexJSON.decode(PlexEnvelope.self, from: data).container.metadata.first else {
            throw PlexError.decoding("snapshot without a title")
        }
        return item
    }
}

extension PlexLibrary {
    /// A title with its markers and chapters, for a download to keep.
    public func metadataSnapshot(_ ratingKey: String) async throws -> PlexMetadataSnapshot {
        let query = [URLQueryItem(name: "includeChapters", value: "1"), URLQueryItem(name: "includeMarkers", value: "1")]
        let response = try await send(.get, "/library/metadata/\(ratingKey)", query, headers: [:])
        return PlexMetadataSnapshot(item: try PlexMetadata.fromSnapshot(response.body), data: response.body)
    }

    /// This app's download queue on the server for the signed-in profile, made on first use.
    public func downloadQueue() async throws -> Int {
        let response = try await send(.post, "/downloadQueue", [], headers: [:], idempotent: true)
        guard let id = try PlexJSON.decode(QueueEnvelope.self, from: response.body).queues.first?.id else {
            throw PlexError.decoding("no download queue")
        }
        return id
    }

    /// Asks the server to convert a title's version into an MP4 for `target`, and returns the queue
    /// item to follow. Multi-part versions come out as one file.
    public func addToDownloadQueue(_ queue: Int, ratingKey: String, mediaIndex: Int, target: DownloadTarget) async throws -> Int {
        let location = try await connection.connection().isLocal ? "lan" : "wan"
        let query = Self.conversionQuery(ratingKey: ratingKey, mediaIndex: mediaIndex, target: target, location: location)
        let headers = [PlexHeader.profileExtra: Self.downloadProfile]
        let response = try await send(.post, "/downloadQueue/\(queue)/add", query, headers: headers, idempotent: false)
        guard let id = try PlexJSON.decode(AddedEnvelope.self, from: response.body).items.first?.id else {
            throw PlexError.decoding("nothing added to the download queue")
        }
        return id
    }

    public func downloadQueueItem(_ queue: Int, item: Int) async throws -> PlexDownloadQueueItem {
        let response = try await send(.get, "/downloadQueue/\(queue)/items/\(item)", [], headers: [:])
        guard let found = try PlexJSON.decode(ItemsEnvelope.self, from: response.body).items.first else {
            throw PlexError.server(status: 404, message: nil)
        }
        return found
    }

    /// The converted title as the server describes the file it made: its container, codecs and streams.
    public func downloadDecision(_ queue: Int, item: Int) async throws -> PlexMetadataSnapshot {
        let response = try await send(.get, "/downloadQueue/\(queue)/item/\(item)/decision", [], headers: [:])
        return PlexMetadataSnapshot(item: try PlexMetadata.fromSnapshot(response.body), data: response.body)
    }

    /// Converts an expired item again with the same settings.
    public func restartDownloadQueueItem(_ queue: Int, item: Int) async throws {
        _ = try await send(.post, "/downloadQueue/\(queue)/items/\(item)/restart", [], headers: [:], idempotent: true)
    }

    /// Drops the item and the server's converted file.
    public func removeFromDownloadQueue(_ queue: Int, item: Int) async throws {
        _ = try await send(.delete, "/downloadQueue/\(queue)/items/\(item)", [], headers: [:], idempotent: true)
    }

    /// Where a download's bytes come from, without the token: the fetch sends `authorizationHeaders()`.
    /// An original file is a part's key; a conversion is its queue item's media.
    public func downloadURL(part: PlexPart) async throws -> URL {
        try await url(part.key, [URLQueryItem(name: "download", value: "1")])
    }

    public func downloadURL(queue: Int, item: Int) async throws -> URL {
        try await url("/downloadQueue/\(queue)/item/\(item)/media", [])
    }

    private func url(_ path: String, _ query: [URLQueryItem]) async throws -> URL {
        let base = try await connection.connection().uri
        guard let url = PlexURL.make(base: base, path: path, query: query) else { throw PlexError.decoding("bad path") }
        return url
    }

    /// An MP4 of H.264 and AAC plays on every iPhone straight from the file; text subtitles ride in it
    /// as `mov_text`.
    static let downloadProfile = "add-transcode-target(type=videoProfile&context=all&protocol=http&container=mp4"
        + "&videoCodec=h264&audioCodec=aac&subtitleCodec=mov_text&replace=true)"

    static func conversionQuery(ratingKey: String, mediaIndex: Int, target: DownloadTarget, location: String) -> [URLQueryItem] {
        [
            ("keys", "/library/metadata/\(ratingKey)"),
            ("mediaIndex", String(mediaIndex)),
            ("protocol", "http"),
            ("directPlay", "0"),
            ("directStream", "1"),
            ("directStreamAudio", "1"),
            ("subtitles", "auto"),
            ("subtitleSize", "100"),
            ("audioBoost", "100"),
            ("videoQuality", "100"),
            ("videoBitrate", String(target.maxVideoBitrateKbps)),
            ("maxVideoBitrate", String(target.maxVideoBitrateKbps)),
            ("videoResolution", target.videoResolution),
            ("autoAdjustQuality", "0"),
            ("location", location),
        ].map { URLQueryItem(name: $0.0, value: $0.1) }
    }
}

private struct QueueEnvelope: Decodable {
    struct Queue: Decodable {
        let id: Int?
        init(from decoder: any Decoder) throws {
            id = try decoder.container(keyedBy: Keys.self).int(.id)
        }
        enum Keys: String, CodingKey { case id }
    }

    let queues: [Queue]

    enum CodingKeys: String, CodingKey { case container = "MediaContainer" }
    enum ContainerKeys: String, CodingKey { case queues = "DownloadQueue" }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        queues = try c.nestedContainer(keyedBy: ContainerKeys.self, forKey: .container).list(.queues)
    }
}

private struct AddedEnvelope: Decodable {
    let items: [QueueEnvelope.Queue]

    enum CodingKeys: String, CodingKey { case container = "MediaContainer" }
    enum ContainerKeys: String, CodingKey { case items = "AddedQueueItems" }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.nestedContainer(keyedBy: ContainerKeys.self, forKey: .container).list(.items)
    }
}

private struct ItemsEnvelope: Decodable {
    let items: [PlexDownloadQueueItem]

    enum CodingKeys: String, CodingKey { case container = "MediaContainer" }
    enum ContainerKeys: String, CodingKey { case items = "DownloadQueueItem" }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.nestedContainer(keyedBy: ContainerKeys.self, forKey: .container).list(.items)
    }
}
