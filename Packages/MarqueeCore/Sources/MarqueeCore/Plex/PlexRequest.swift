import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET", post = "POST", put = "PUT", delete = "DELETE"
}

/// One HTTP request to plex.tv or a Plex server, before identity headers are added.
public struct PlexRequest: Sendable, CustomStringConvertible {
    public var method: HTTPMethod
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval
    /// Safe to send twice. Only these are retried after a dropped connection.
    public var isIdempotent: Bool

    public init(
        method: HTTPMethod = .get,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 20,
        isIdempotent: Bool? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.isIdempotent = isIdempotent ?? (method == .get)
    }

    /// Method and URL without any token; headers are left out because they carry it.
    public var description: String { "\(method.rawValue) \(url.removingPlexToken.absoluteString)" }
}

/// An HTTP answer, whatever its status.
public struct PlexHTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public var headers: [String: String]

    public init(status: Int, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    /// One header's value; header names are case-insensitive.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public enum PlexURL {
    /// Joins a base URL, a Plex path such as `/library/sections/1/all` or `/:/scrobble`, and a query.
    /// Query names and values are encoded strictly (only RFC 3986 unreserved characters stay bare), so a
    /// nested path such as the photo transcoder's `url=` survives intact.
    public static func make(base: URL, path: String, query: [URLQueryItem] = []) -> URL? {
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        text += path.hasPrefix("/") ? path : "/" + path
        if !query.isEmpty {
            text += "?" + query.map { encode($0.name) + "=" + encode($0.value ?? "") }.joined(separator: "&")
        }
        return URL(string: text)
    }

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
