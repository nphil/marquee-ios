import Foundation

/// Where HomeLabber answers and the read-only token it issued for Marquee's quality map.
public struct HomeLabberConfig: Sendable, Hashable, Codable {
    public var address: URL
    public var token: String

    public init(address: URL, token: String) {
        self.address = address
        self.token = token
    }

    /// The start of every token HomeLabber makes for Marquee. Any other kind of HomeLabber credential is refused
    /// instead of kept on the phone, since the quality map needs no more than its own.
    public static let tokenPrefix = "hlmq_"

    /// Checks what was typed into the settings page. The address keeps any base path.
    public static func parse(address text: String, token: String) -> Result<HomeLabberConfig, Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return .failure(.scheme) }
        guard let host = components.host, !host.isEmpty, !host.contains(" "), components.user == nil,
              components.query == nil, components.fragment == nil, let url = components.url else { return .failure(.host) }
        if scheme == "http", !HomeNetwork.contains(host) { return .failure(.plaintext) }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix(Self.tokenPrefix), (16...512).contains(token.count),
              token.allSatisfy({ $0.isASCII && !$0.isWhitespace && !$0.isNewline }) else {
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
        /// The score under HomeLabber's phone model, which judges the picture at a phone's size and distance. Only
        /// curve points carry it (the phone tiers hold it in `vmaf`), and entries scored before it existed lack it.
        public var vmafPhone: Double?

        public init(kbps: Int, vmaf: Double, height: Int, vmafPhone: Double? = nil) {
            self.kbps = kbps
            self.vmaf = vmaf
            self.height = height
            self.vmafPhone = vmafPhone
        }

        enum CodingKeys: String, CodingKey { case kbps, vmaf, height, vmafPhone }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let kbps = c.int(.kbps), let vmaf = c.double(.vmaf), let height = c.int(.height) else {
                throw HomeLabberError.notHomeLabber
            }
            self.init(kbps: kbps, vmaf: vmaf, height: height, vmafPhone: c.double(.vmafPhone))
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
    /// The tiers under the phone model; nil where HomeLabber has none for the title. `tiers(for:)` says which apply.
    public var phoneTiers: [DownloadTier: Point]?
    /// Every encode measured: what Auto streams by (`QualityCurve`).
    public var curve: [Point]

    public init(
        ratingKey: String, mediaID: String, scoredAt: Date? = nil, encoder: String? = nil, sourceHeight: Int? = nil,
        fps: Double? = nil, tiers: [DownloadTier: Point], phoneTiers: [DownloadTier: Point]? = nil, curve: [Point] = []
    ) {
        self.ratingKey = ratingKey
        self.mediaID = mediaID
        self.scoredAt = scoredAt
        self.encoder = encoder
        self.sourceHeight = sourceHeight
        self.fps = fps
        self.tiers = tiers
        self.phoneTiers = phoneTiers
        self.curve = curve
    }

    enum CodingKeys: String, CodingKey { case ratingKey, mediaId, scoredAt, encoder, sourceHeight, fps, tiers, phoneTiers, curve }
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
        let phoneValues = try? c.nestedContainer(keyedBy: TierKeys.self, forKey: .phoneTiers)
        self.init(
            ratingKey: ratingKey, mediaID: mediaID, scoredAt: c.date(.scoredAt), encoder: c.string(.encoder),
            sourceHeight: c.int(.sourceHeight), fps: c.double(.fps), tiers: Self.tiers(in: tierValues),
            phoneTiers: phoneValues.map(Self.tiers(in:)), curve: c.list(.curve)
        )
    }

    private static func tiers(in values: KeyedDecodingContainer<TierKeys>) -> [DownloadTier: Point] {
        var tiers: [DownloadTier: Point] = [:]
        for tier in DownloadTier.allCases {
            tiers[tier] = try? values.decodeIfPresent(Point.self, forKey: TierKeys(stringValue: tier.rawValue))
        }
        return tiers
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

    /// HomeLabber's word on the title: its measurements, that the file is smaller than any conversion, or
    /// nothing yet. Throws when HomeLabber cannot be reached or refuses the token.
    public func answer(server: String, ratingKey: String) async throws -> QualityMapAnswer {
        let path = "/api/media-quality/v1/servers/\(PlexURL.encode(server))/items/\(PlexURL.encode(ratingKey))"
        let response = try await send(path, timeout: 10)
        switch response.status {
        case 200..<300: return .scored(try Self.decode(QualityMapEntry.self, response.body))
        case 404: return Self.unmeasured(response.body)
        default: throw Self.error(status: response.status)
        }
    }

    /// A 404 says either "Not scored yet" or `useOriginal`: the file is smaller than the smallest conversion.
    private static func unmeasured(_ body: Data) -> QualityMapAnswer {
        guard let found = try? JSONDecoder().decode(UseOriginalBody.self, from: body), found.useOriginal else { return .unscored }
        return .useOriginal(sourceKbps: found.sourceKbps, mediaID: found.mediaID)
    }

    private struct UseOriginalBody: Decodable {
        var useOriginal: Bool
        var sourceKbps: Int?
        var mediaID: String?

        enum CodingKeys: String, CodingKey { case useOriginal, sourceKbps, mediaId }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            useOriginal = c.bool(.useOriginal) ?? false
            sourceKbps = c.int(.sourceKbps).flatMap { $0 > 0 ? $0 : nil }
            mediaID = c.string(.mediaId)
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
