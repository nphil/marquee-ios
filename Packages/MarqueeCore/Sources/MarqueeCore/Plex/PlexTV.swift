import Foundation

/// A sign-in code from plex.tv.
public struct PlexPIN: Sendable, Hashable, Decodable {
    public var id: Int
    /// The long code for the browser flow, or the 4-character code typed at plex.tv/link.
    public var code: String
    public var expiresAt: Date?
    /// Set once the user approved the sign-in.
    public var authToken: String?

    public init(id: Int, code: String, expiresAt: Date? = nil, authToken: String? = nil) {
        self.id = id
        self.code = code
        self.expiresAt = expiresAt
        self.authToken = authToken
    }

    enum CodingKeys: String, CodingKey {
        case id, code, expiresAt, authToken
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.int(.id), let code = c.string(.code) else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "PIN without id or code"))
        }
        self.init(id: id, code: code, expiresAt: c.date(.expiresAt), authToken: c.string(.authToken).flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// A profile in the user's Plex Home, or the signed-in account itself (`PlexTV.account()`).
/// Encodes to the keys it decodes from, so the app can keep the active profile between launches.
public struct PlexHomeUser: Sendable, Hashable, Identifiable, Codable {
    public var id: Int
    public var uuid: String
    public var title: String
    public var thumb: String?
    public var isAdmin: Bool
    /// Switching to this profile needs its PIN.
    public var isProtected: Bool
    /// A managed profile with content restrictions.
    public var isRestricted: Bool
    public var isGuest: Bool

    enum CodingKeys: String, CodingKey {
        case id, uuid, title, username, thumb, admin, homeAdmin, protected, restricted, guest
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.int(.id) ?? 0
        uuid = c.string(.uuid) ?? ""
        title = c.string(.title) ?? c.string(.username) ?? ""
        thumb = c.string(.thumb)
        // The Home list says `admin`; the account answer (`/api/v2/user`) says `homeAdmin`.
        isAdmin = c.bool(.admin) ?? c.bool(.homeAdmin) ?? false
        isProtected = c.bool(.protected) ?? false
        isRestricted = c.bool(.restricted) ?? false
        isGuest = c.bool(.guest) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(uuid, forKey: .uuid)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(thumb, forKey: .thumb)
        try c.encode(isAdmin, forKey: .admin)
        try c.encode(isProtected, forKey: .protected)
        try c.encode(isRestricted, forKey: .restricted)
        try c.encode(isGuest, forKey: .guest)
    }
}

/// The plex.tv account API: sign-in, servers, Home profiles.
public struct PlexTV: Sendable {
    public static let base = URL(string: "https://plex.tv")!
    /// Carries the account token once signed in.
    public let http: PlexHTTPClient

    public init(http: PlexHTTPClient) {
        self.http = http
    }

    // MARK: Sign-in

    /// Creates a sign-in code. `strong` gives the code for the browser flow; otherwise a 4-character
    /// code to type at plex.tv/link.
    public func createPIN(strong: Bool = true) async throws -> PlexPIN {
        try await http.decode(PlexPIN.self, from: request(.post, "/api/v2/pins", ["strong": strong ? "true" : "false"]))
    }

    /// The plex.tv page that approves `pin`, opened in a browser sheet while the app polls the code.
    public func authURL(for pin: PlexPIN) -> URL {
        let parameters = [
            ("clientID", http.identity.clientIdentifier),
            ("code", pin.code),
            ("context[device][product]", http.identity.product),
        ]
        let fragment = parameters.map { PlexURL.encode($0.0) + "=" + PlexURL.encode($0.1) }.joined(separator: "&")
        return URL(string: "https://app.plex.tv/auth#?" + fragment)!
    }

    /// Re-reads `pin`. A PIN plex.tv no longer knows has expired.
    public func checkPIN(_ pin: PlexPIN) async throws -> PlexPIN {
        do {
            return try await http.decode(PlexPIN.self, from: request(.get, "/api/v2/pins/\(pin.id)", ["code": pin.code]))
        } catch PlexError.server(status: 404, _) {
            throw PlexError.pinExpired
        }
    }

    /// Polls `pin` until the user approves it and returns the account token. Throws `pinExpired` when
    /// the code runs out and `CancellationError` when the calling task is cancelled.
    public func waitForToken(
        _ pin: PlexPIN,
        every interval: Duration = .seconds(1),
        now: @Sendable () -> Date = { Date() },
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> String {
        while true {
            try Task.checkCancellation()
            let current = try await checkPIN(pin)
            if let token = current.authToken { return token }
            if let expiry = current.expiresAt ?? pin.expiresAt, expiry <= now() { throw PlexError.pinExpired }
            try await sleep(interval)
        }
    }

    // MARK: Account

    /// The user the token belongs to: the account, or the Home profile switched to.
    public func account() async throws -> PlexHomeUser {
        try await http.decode(PlexHomeUser.self, from: request(.get, "/api/v2/user"))
    }

    /// Servers the account can use, with this user's token for each: its own, its Plex Home's and
    /// those friends share, in that order and otherwise as plex.tv lists them.
    public func servers() async throws -> [PlexServer] {
        let query = ["includeHttps": "1", "includeRelay": "1", "includeIPv6": "1"]
        let servers = try await http.decode([PlexResource].self, from: request(.get, "/api/v2/resources", query)).compactMap(\.server)
        return servers.enumerated()
            .sorted { ($0.element.listOrder, $0.offset) < ($1.element.listOrder, $1.offset) }
            .map(\.element)
    }

    /// Profiles in the user's Plex Home; empty for an account without a Home.
    public func homeUsers() async throws -> [PlexHomeUser] {
        try await http.decode(HomeUsers.self, from: request(.get, "/api/v2/home/users")).users
    }

    /// Switches to `user` and returns that profile's account token. A protected profile needs its PIN.
    public func switchHomeUser(_ user: PlexHomeUser, pin: String? = nil) async throws -> String {
        let query = pin.map { ["pin": $0] } ?? [:]
        let switched: SwitchedUser
        do {
            switched = try await http.decode(SwitchedUser.self, from: request(.post, "/api/v2/home/users/\(user.uuid)/switch", query))
        } catch PlexError.unauthorized where pin != nil {
            throw PlexError.profilePINRejected
        } catch PlexError.server(status: 403, _) where pin != nil {
            throw PlexError.profilePINRejected
        }
        guard let token = switched.authToken else { throw PlexError.decoding("switch answer without a token") }
        return token
    }

    private func request(_ method: HTTPMethod, _ path: String, _ query: [String: String] = [:]) -> PlexRequest {
        let items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return PlexRequest(method: method, url: PlexURL.make(base: Self.base, path: path, query: items)!)
    }
}

/// plex.tv answers the Home list as `{"users": [...]}`; older servers sent a bare array.
private struct HomeUsers: Decodable {
    let users: [PlexHomeUser]

    enum CodingKeys: String, CodingKey { case users }

    init(from decoder: any Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self), keyed.contains(.users) {
            users = keyed.list(.users)
        } else {
            users = (try? [PlexHomeUser](from: decoder)) ?? []
        }
    }
}

private struct SwitchedUser: Decodable {
    let authToken: String?
}
