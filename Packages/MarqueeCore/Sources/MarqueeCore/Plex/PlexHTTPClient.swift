import Foundation

/// Sends requests with the app's identity headers and one token (the account's for plex.tv, a server's
/// own access token for that server) and turns failures into `PlexError`. It logs nothing.
public actor PlexHTTPClient {
    public nonisolated let identity: PlexClientIdentity
    private let transport: any PlexTransport
    private let retryDelay: Duration
    private var token: String?

    public init(
        identity: PlexClientIdentity,
        token: String? = nil,
        transport: any PlexTransport = URLSessionTransport(),
        retryDelay: Duration = .milliseconds(300)
    ) {
        self.identity = identity
        self.token = token
        self.transport = transport
        self.retryDelay = retryDelay
    }

    /// Replaces the token, e.g. after a profile switch.
    public func setToken(_ token: String?) {
        self.token = token
    }

    /// Sends `request` and returns a 2xx answer. A read that hits a dropped connection is retried once;
    /// writes never are. Cancelling the calling task throws `CancellationError`.
    public func send(_ request: PlexRequest) async throws -> PlexHTTPResponse {
        var request = request
        for (name, value) in identity.headers(token: token) where request.headers[name] == nil {
            request.headers[name] = value
        }
        let response = try await deliver(request)
        switch response.status {
        case 200..<300:
            return response
        case 401:
            throw PlexError.unauthorized
        default:
            throw PlexError.server(status: response.status, message: PlexJSON.errorMessage(in: response.body))
        }
    }

    /// Sends `request` and decodes the JSON answer. Decoding runs off the actor.
    public nonisolated func decode<T: Decodable & Sendable>(_ type: T.Type, from request: PlexRequest) async throws -> T {
        let response = try await send(request)
        return try PlexJSON.decode(T.self, from: response.body)
    }

    private func deliver(_ request: PlexRequest) async throws -> PlexHTTPResponse {
        do {
            return try await transport.send(request)
        } catch let failure as NetworkFailure {
            guard request.isIdempotent, failure.isTransient else { throw PlexError.unreachable(failure) }
        }
        try await Task.sleep(for: retryDelay)
        do {
            return try await transport.send(request)
        } catch let failure as NetworkFailure {
            throw PlexError.unreachable(failure)
        }
    }
}

enum PlexJSON {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as DecodingError {
            throw PlexError.decoding(summary(of: error))
        }
    }

    /// The first message in a plex.tv error body: `{"errors":[{"code":…,"message":"…"}]}`.
    static func errorMessage(in body: Data) -> String? {
        struct Body: Decodable {
            struct Item: Decodable { let message: String? }
            let errors: [Item]?
        }
        return (try? JSONDecoder().decode(Body.self, from: body))?.errors?.first?.message
    }

    private static func summary(of error: DecodingError) -> String {
        let (context, kind): (DecodingError.Context?, String) = switch error {
        case .typeMismatch(_, let context): (context, "type mismatch")
        case .valueNotFound(_, let context): (context, "missing value")
        case .keyNotFound(let key, let context): (context, "missing key \(key.stringValue)")
        case .dataCorrupted(let context): (context, "malformed data")
        @unknown default: (nil, "unknown")
        }
        let path = context?.codingPath.map(\.stringValue).joined(separator: ".") ?? ""
        return path.isEmpty ? kind : "\(kind) at \(path)"
    }
}
