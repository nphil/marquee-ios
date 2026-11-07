import Foundation

/// A tuner's `discover.json`.
public struct HDHomeRunDevice: Sendable, Hashable {
    public var deviceID: String
    public var friendlyName: String
    public var modelNumber: String?
    public var firmwareVersion: String?
    public var tunerCount: Int
    public var baseURL: URL?
    public var lineupURL: URL?
}

/// One entry of a tuner's `lineup.json`. LumaTuner sends only the number, name and URL; real
/// HDHomeRuns add codecs, HD, DRM and favourites.
public struct HDHomeRunChannel: Sendable, Hashable, Decodable {
    public var number: String
    public var name: String
    public var url: URL?
    public var videoCodec: String?
    public var audioCodec: String?
    public var isHD: Bool
    public var isProtected: Bool
    public var isFavorite: Bool

    public init(
        number: String,
        name: String,
        url: URL? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        isHD: Bool = false,
        isProtected: Bool = false,
        isFavorite: Bool = false
    ) {
        self.number = number
        self.name = name
        self.url = url
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.isHD = isHD
        self.isProtected = isProtected
        self.isFavorite = isFavorite
    }

    enum CodingKeys: String, CodingKey {
        case number = "GuideNumber", name = "GuideName", url = "URL"
        case videoCodec = "VideoCodec", audioCodec = "AudioCodec", hd = "HD", drm = "DRM", favorite = "Favorite"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = c.string(.number) ?? ""
        name = c.string(.name) ?? ""
        url = c.string(.url).flatMap(URL.init(string:))
        videoCodec = c.string(.videoCodec)
        audioCodec = c.string(.audioCodec)
        isHD = c.bool(.hd) ?? false
        isProtected = c.bool(.drm) ?? false
        isFavorite = c.bool(.favorite) ?? false
    }

    /// Codecs the phone's renderer decodes; a missing codec field means "try".
    public var phoneDecodes: Bool {
        let video = videoCodec?.uppercased()
        let audio = audioCodec?.uppercased()
        let videoOK = video.map { ["MPEG2", "H264", "HEVC"].contains($0) } ?? true
        let audioOK = audio.map { ["AC3", "EAC3", "AAC", "MPEG"].contains($0) } ?? true
        return videoOK && audioOK
    }
}

/// Reads a tuner's own HDHomeRun HTTP API (https://info.hdhomerun.com/info/http_api).
public struct HDHomeRunClient: Sendable {
    private let transport: any PlexTransport

    public init(transport: any PlexTransport = URLSessionTransport()) {
        self.transport = transport
    }

    /// `discover.json`, the reachability check before a direct tune.
    public func discover(_ base: URL, timeout: TimeInterval = 0.5) async throws -> HDHomeRunDevice {
        let wire = try await get(Discover.self, base.appendingPathComponent("discover.json"), timeout: timeout)
        return HDHomeRunDevice(
            deviceID: wire.deviceID ?? "",
            friendlyName: wire.friendlyName ?? "",
            modelNumber: wire.modelNumber,
            firmwareVersion: wire.firmwareVersion,
            tunerCount: wire.tunerCount ?? 1,
            baseURL: wire.baseURL.flatMap(URL.init(string:)),
            lineupURL: wire.lineupURL.flatMap(URL.init(string:))
        )
    }

    public func lineup(_ base: URL, timeout: TimeInterval = 5) async throws -> [HDHomeRunChannel] {
        try await get([HDHomeRunChannel].self, base.appendingPathComponent("lineup.json"), timeout: timeout)
    }

    private func get<T: Decodable>(_ type: T.Type, _ url: URL, timeout: TimeInterval) async throws -> T {
        let response: PlexHTTPResponse
        do {
            response = try await transport.send(PlexRequest(url: url, timeout: timeout))
        } catch let failure as NetworkFailure {
            throw PlexError.unreachable(failure)
        }
        guard (200..<300).contains(response.status) else {
            throw PlexError.server(status: response.status, message: nil)
        }
        return try PlexJSON.decode(T.self, from: response.body)
    }

    private struct Discover: Decodable {
        let deviceID: String?
        let friendlyName: String?
        let modelNumber: String?
        let firmwareVersion: String?
        let tunerCount: Int?
        let baseURL: String?
        let lineupURL: String?

        enum CodingKeys: String, CodingKey {
            case deviceID = "DeviceID", friendlyName = "FriendlyName", modelNumber = "ModelNumber"
            case firmwareVersion = "FirmwareVersion", tunerCount = "TunerCount", baseURL = "BaseURL", lineupURL = "LineupURL"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            deviceID = c.string(.deviceID)
            friendlyName = c.string(.friendlyName)
            modelNumber = c.string(.modelNumber)
            firmwareVersion = c.string(.firmwareVersion)
            tunerCount = c.int(.tunerCount)
            baseURL = c.string(.baseURL)
            lineupURL = c.string(.lineupURL)
        }
    }
}
