import Foundation

/// Where HomeLabber answers and the read-only token it issued for Marquee's quality map.
public struct HomeLabberConfig: Sendable, Hashable, Codable {
    public var address: URL
    public var token: String

    public init(address: URL, token: String) {
        self.address = address
        self.token = token
    }

    /// Checks what was typed into the settings page. The address keeps any base path.
    public static func parse(address text: String, token: String) -> Result<HomeLabberConfig, Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return .failure(.scheme) }
        guard let host = components.host, !host.isEmpty, !host.contains(" "), components.user == nil,
              components.query == nil, components.fragment == nil, let url = components.url else { return .failure(.host) }
        if scheme == "http", !HomeNetwork.contains(host) { return .failure(.plaintext) }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (16...512).contains(token.count), token.allSatisfy({ $0.isASCII && !$0.isWhitespace && !$0.isNewline }) else {
            return .failure(.token)
        }
        return .success(HomeLabberConfig(address: url, token: token))
    }

    public enum Problem: Error, Sendable, Equatable {
        /// Neither https:// nor http://.
        case scheme
        case host
        /// Plain http:// to a host outside the home network.
        case plaintext
        case token
    }
}

public enum HomeLabberError: Error, Sendable, Equatable {
    case unreachable
    case timedOut
    /// The address answered but refused the token.
    case badToken
    /// The address answered, but not like HomeLabber's quality map.
    case notHomeLabber
}

/// How far HomeLabber's nightly scoring of the Plex library has come.
public struct QualityMapStatus: Sendable, Hashable, Decodable {
    public var enabled: Bool
    public var scored: Int
    public var total: Int
    public var running: Bool
    public var lastRun: Date?
    /// The encoder the scores were measured with, such as `h264_vaapi`.
    public var encoder: String?

    public init(enabled: Bool, scored: Int, total: Int, running: Bool, lastRun: Date?, encoder: String?) {
        self.enabled = enabled
        self.scored = scored
        self.total = total
        self.running = running
        self.lastRun = lastRun
        self.encoder = encoder
    }

    enum CodingKeys: String, CodingKey { case enabled, scored, total, running, lastRun, encoder }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let enabled = c.bool(.enabled), let scored = c.int(.scored), let total = c.int(.total) else {
            throw HomeLabberError.notHomeLabber
        }
        self.enabled = enabled
        self.scored = scored
        self.total = total
        running = c.bool(.running) ?? false
        lastRun = c.date(.lastRun)
        encoder = c.string(.encoder)
    }
}

/// One title's measured tiers: for each, the H.264 video bitrate (Plex's `-b:0`) whose VMAF reaches
/// the tier's score at the size it names. Sizes are Plex's classes, 480 to 1080; nothing is scored
/// at 2160.
public struct QualityMapEntry: Sendable, Hashable, Decodable {
    public struct Point: Sendable, Hashable, Decodable {
        public var kbps: Int
        public var vmaf: Double
        public var height: Int

        public init(kbps: Int, vmaf: Double, height: Int) {
            self.kbps = kbps
            self.vmaf = vmaf
            self.height = height
        }

        enum CodingKeys: String, CodingKey { case kbps, vmaf, height }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let kbps = c.int(.kbps), let vmaf = c.double(.vmaf), let height = c.int(.height) else {
                throw HomeLabberError.notHomeLabber
            }
            self.init(kbps: kbps, vmaf: vmaf, height: height)
        }
    }

    public var ratingKey: String
    /// The Plex media version scored; a replaced file has another, and its scores no longer apply.
    public var mediaID: String
    public var scoredAt: Date?
    public var encoder: String?
    public var sourceHeight: Int?
    public var fps: Double?
    public var tiers: [DownloadTier: Point]
    /// Every encode measured, for display.
    public var curve: [Point]

    public init(
        ratingKey: String, mediaID: String, scoredAt: Date? = nil, encoder: String? = nil, sourceHeight: Int? = nil,
        fps: Double? = nil, tiers: [DownloadTier: Point], curve: [Point] = []
    ) {
        self.ratingKey = ratingKey
        self.mediaID = mediaID
        self.scoredAt = scoredAt
        self.encoder = encoder
        self.sourceHeight = sourceHeight
        self.fps = fps
        self.tiers = tiers
        self.curve = curve
    }

    enum CodingKeys: String, CodingKey { case ratingKey, mediaId, scoredAt, encoder, sourceHeight, fps, tiers, curve }
    struct TierKeys: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let ratingKey = c.string(.ratingKey), let mediaID = c.string(.mediaId),
              let tierValues = try? c.nestedContainer(keyedBy: TierKeys.self, forKey: .tiers) else { throw HomeLabberError.notHomeLabber }
        var tiers: [DownloadTier: Point] = [:]
        for tier in DownloadTier.allCases {
            tiers[tier] = try? tierValues.decodeIfPresent(Point.self, forKey: TierKeys(stringValue: tier.rawValue))
        }
        self.init(
            ratingKey: ratingKey, mediaID: mediaID, scoredAt: c.date(.scoredAt), encoder: c.string(.encoder),
            sourceHeight: c.int(.sourceHeight), fps: c.double(.fps), tiers: tiers, curve: c.list(.curve)
        )
    }
}

/// HomeLabber's quality map API (`/api/media-quality/v1`), authorized with its bearer token.
public struct HomeLabberClient: Sendable {
    public let config: HomeLabberConfig
    private let transport: any PlexTransport

    public init(config: HomeLabberConfig, transport: any PlexTransport = URLSessionTransport()) {
        self.config = config
        self.transport = transport
    }

    public func status() async throws -> QualityMapStatus {
        let response = try await send("/api/media-quality/v1/status", timeout: 10)
        guard (200..<300).contains(response.status) else { throw Self.error(status: response.status) }
        return try Self.decode(QualityMapStatus.self, response.body)
    }

    /// The title's measured tiers; nil until HomeLabber has scored it.
    public func entry(server: String, ratingKey: String) async throws -> QualityMapEntry? {
        let path = "/api/media-quality/v1/servers/\(PlexURL.encode(server))/items/\(PlexURL.encode(ratingKey))"
        let response = try await send(path, timeout: 10)
        switch response.status {
        case 200..<300: return try Self.decode(QualityMapEntry.self, response.body)
        case 404: return nil
        default: throw Self.error(status: response.status)
        }
    }

    private static func error(status: Int) -> HomeLabberError {
        status == 401 || status == 403 ? .badToken : .notHomeLabber
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ body: Data) throws -> T {
        guard let value = try? JSONDecoder().decode(T.self, from: body) else { throw HomeLabberError.notHomeLabber }
        return value
    }

    private func send(_ path: String, timeout: TimeInterval) async throws -> PlexHTTPResponse {
        guard let url = PlexURL.make(base: config.address, path: path) else { throw HomeLabberError.notHomeLabber }
        let headers = ["Authorization": "Bearer \(config.token)", "Accept": "application/json"]
        do {
            return try await transport.send(PlexRequest(method: .get, url: url, headers: headers, timeout: timeout))
        } catch let failure as NetworkFailure {
            throw failure == .timedOut ? HomeLabberError.timedOut : HomeLabberError.unreachable
        }
    }
}
