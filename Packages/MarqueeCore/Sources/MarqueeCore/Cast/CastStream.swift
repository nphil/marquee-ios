import Foundation

/// What a Chromecast fetches for a route, and from which of the server's addresses.
public struct CastStream: Sendable, Hashable {
    /// Carries a transient token, never the account's: the receiver shows it to anyone who asks.
    public var url: URL
    /// `video/mp4` for the file, `application/x-mpegURL` for the server's HLS.
    public var contentType: String
    /// The server stream's session, for timeline reports and `stopTranscode`; nil for the file.
    public var session: String?

    /// The address the receiver uses. Its player loads HLS from an HTTPS page, so a plain-http address
    /// is swapped for the same machine's plex.direct name, or another HTTPS address on the same side
    /// of the network; the phone's own address stays when there is none.
    public static func address(current: PlexConnection, among connections: [PlexConnection]) -> PlexConnection {
        guard !current.isHTTPS else { return current }
        let secure = connections.filter { $0.isHTTPS && $0.isLocal == current.isLocal }
        let label = (current.uri.host() ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: ":", with: "-")
        if let sameMachine = secure.first(where: { $0.uri.host()?.split(separator: ".").first.map(String.init) == label }) {
            return sameMachine
        }
        return secure.first { !$0.isRelay } ?? current
    }

    /// The file itself.
    public static func file(part: PlexPart, base: URL, token: String) -> CastStream? {
        guard let url = PlexURL.make(base: base, path: part.key, query: [URLQueryItem(name: PlexHeader.token, value: token)]) else {
            return nil
        }
        return CastStream(url: url, contentType: "video/mp4", session: nil)
    }

    /// The server's HLS of `request`, made for the Default Media Receiver: H.264 and AAC or MP3 in
    /// MPEG-TS segments, under the Chromecast platform. The request's offset should be 0, so the stream's
    /// times are the movie's and the receiver starts at the resume point itself.
    public static func transcode(
        _ request: TranscodeRequest,
        base: URL,
        identity: PlexClientIdentity,
        isLocal: Bool,
        token: String
    ) -> CastStream? {
        var sender = identity
        sender.platform = "Chromecast"
        let headers = sender.headers(token: nil)
            .filter { $0.key.hasPrefix("X-Plex-") }
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        let profile = URLQueryItem(
            name: "X-Plex-Client-Profile-Extra",
            value: "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts"
                + "&videoCodec=h264&audioCodec=aac,mp3&replace=true)"
        )
        let query = request.queryItems(location: isLocal ? "lan" : "wan") + headers + [profile, URLQueryItem(name: PlexHeader.token, value: token)]
        guard let url = PlexURL.make(base: base, path: "/video/:/transcode/universal/start.m3u8", query: query) else { return nil }
        return CastStream(url: url, contentType: "application/x-mpegURL", session: request.session)
    }
}

extension PlexLibrary {
    /// A token for one server that a receiver may hold instead of the account's: Plex's transient
    /// delegation token, which the server forgets after 48 hours or a restart.
    public func transientToken() async throws -> String {
        let query = [URLQueryItem(name: "type", value: "delegation"), URLQueryItem(name: "scope", value: "all")]
        let response = try await send(.get, "/security/token", query, headers: [:])
        guard let token = try PlexJSON.decode(TransientTokenEnvelope.self, from: response.body).container.token, !token.isEmpty else {
            throw PlexError.decoding("transient token missing")
        }
        return token
    }
}

private struct TransientTokenEnvelope: Decodable {
    struct Container: Decodable { let token: String? }
    let container: Container

    enum CodingKeys: String, CodingKey { case container = "MediaContainer" }
}
