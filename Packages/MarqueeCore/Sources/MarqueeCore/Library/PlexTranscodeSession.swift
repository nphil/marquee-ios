import Foundation

/// The server's own account of one transcode, from `/transcode/sessions`: what it converts, how fast,
/// and whether its hardware does the work.
public struct PlexTranscodeSession: Sendable, Hashable, Decodable {
    /// `/transcode/sessions/<session>`, where `<session>` is `TranscodeRequest.session`.
    public var key: String
    /// Encoding speed as a multiple of real time; below 1 the player outruns it.
    public var speed: Double?
    /// The server paused encoding because it is far enough ahead of the player.
    public var throttled: Bool?
    /// "transcode", "copy" or "burn" (subtitles).
    public var videoDecision: String?
    public var audioDecision: String?
    public var subtitleDecision: String?
    /// Decoding and encoding both run on the server's GPU.
    public var hardwareFullPipeline: Bool?
    public var hardwareDecoding: String?
    public var hardwareEncoding: String?

    enum CodingKeys: String, CodingKey {
        case key, speed, throttled, videoDecision, audioDecision, subtitleDecision
        case hardwareFullPipeline = "transcodeHwFullPipeline"
        case hardwareDecoding = "transcodeHwDecoding"
        case hardwareEncoding = "transcodeHwEncoding"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.string(.key) ?? ""
        speed = c.double(.speed)
        throttled = c.bool(.throttled)
        videoDecision = c.string(.videoDecision)
        audioDecision = c.string(.audioDecision)
        subtitleDecision = c.string(.subtitleDecision)
        hardwareFullPipeline = c.bool(.hardwareFullPipeline)
        hardwareDecoding = c.string(.hardwareDecoding)
        hardwareEncoding = c.string(.hardwareEncoding)
    }
}

private struct TranscodeSessionsEnvelope: Decodable {
    let sessions: [PlexTranscodeSession]

    enum CodingKeys: String, CodingKey { case container = "MediaContainer" }
    enum ContainerKeys: String, CodingKey { case sessions = "TranscodeSession" }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try c.nestedContainer(keyedBy: ContainerKeys.self, forKey: .container).list(.sessions)
    }
}

extension PlexLibrary {
    /// The server's state of the transcode started with `session`, or nil once it has ended. The list
    /// holds every transcode on the server, other users' too.
    public func transcodeSession(_ session: String) async throws -> PlexTranscodeSession? {
        let response = try await send(.get, "/transcode/sessions", [], headers: [:])
        let sessions = try PlexJSON.decode(TranscodeSessionsEnvelope.self, from: response.body).sessions
        return sessions.first { $0.key.split(separator: "/").last.map(String.init) == session }
    }
}
