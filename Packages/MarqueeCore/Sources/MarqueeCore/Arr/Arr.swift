import Foundation

/// Radarr holds movies and Sonarr holds series. Both speak one HTTP API (v3) and take the key the same way.
public enum ArrKind: String, Sendable, Hashable, CaseIterable, Codable {
    case radarr, sonarr

    var appName: String { rawValue.capitalized }
}

/// Where Sonarr or Radarr answers and the API key it accepts. The settings page takes both the way
/// Bazarr's does, so the same rules apply.
public struct ArrConfig: Sendable, Hashable, Codable {
    public var address: URL
    public var apiKey: String

    public init(address: URL, apiKey: String) {
        self.address = address
        self.apiKey = apiKey
    }

    public typealias Problem = BazarrConfig.Problem

    public static func parse(address text: String, key: String) -> Result<ArrConfig, Problem> {
        BazarrConfig.parse(address: text, key: key).map { ArrConfig(address: $0.address, apiKey: $0.apiKey) }
    }
}

public enum ArrError: Error, Sendable, Equatable {
    case unreachable
    case timedOut
    /// The address answered but refused the key.
    case badKey
    /// The address answered, but not like this service: another app, a wrong base path, or the other
    /// one of Sonarr and Radarr.
    case notArr
    /// An error of its own, with the status and the message it gave.
    case failed(status: Int, message: String?)
}

/// The title to remove, by the id its service knows it by: Radarr by TMDB, Sonarr by TVDB.
public enum ArrTitle: Sendable, Equatable {
    case movie(tmdbID: Int, title: String, year: Int?)
    case series(tvdbID: Int, title: String)

    public var kind: ArrKind {
        switch self {
        case .movie: .radarr
        case .series: .sonarr
        }
    }
}

/// The calls a delete makes of Sonarr and Radarr.
public protocol ArrAccount: Sendable {
    /// Whether the service that holds titles of this kind is connected.
    func isConnected(_ kind: ArrKind) -> Bool
    /// Removes the title with its files and keeps it from coming back through a list; true when the
    /// service held it.
    func remove(_ title: ArrTitle) async throws -> Bool
}

/// The connected Sonarr and Radarr, whichever of them are.
public struct ArrServices: ArrAccount {
    public var radarr: ArrClient?
    public var sonarr: ArrClient?

    public init(radarr: ArrClient? = nil, sonarr: ArrClient? = nil) {
        self.radarr = radarr
        self.sonarr = sonarr
    }

    public func isConnected(_ kind: ArrKind) -> Bool {
        client(kind) != nil
    }

    public func remove(_ title: ArrTitle) async throws -> Bool {
        guard let client = client(title.kind) else { throw ArrError.unreachable }
        return try await client.remove(title)
    }

    private func client(_ kind: ArrKind) -> ArrClient? {
        switch kind {
        case .radarr: radarr
        case .sonarr: sonarr
        }
    }
}

/// Sonarr's or Radarr's own HTTP API, authorized with its `X-Api-Key` header.
public struct ArrClient: Sendable {
    /// The service deletes the files before it answers, so a removal may take a while.
    static let removeTimeout: TimeInterval = 120

    public let kind: ArrKind
    public let config: ArrConfig
    private let transport: any PlexTransport

    public init(kind: ArrKind, config: ArrConfig, transport: any PlexTransport = URLSessionTransport()) {
        self.kind = kind
        self.config = config
        self.transport = transport
    }

    /// Its version. The call needs the key, so it proves the address and the key together.
    public func version() async throws -> String {
        struct Body: Decodable {
            let version: String
            let appName: String?
        }
        let response = try await send(.get, "/api/v3/system/status")
        guard (200..<300).contains(response.status) else { throw failure(response) }
        guard let body = try? JSONDecoder().decode(Body.self, from: response.body),
              body.appName.map({ $0.caseInsensitiveCompare(kind.appName) == .orderedSame }) ?? true
        else { throw ArrError.notArr }
        return body.version
    }

    /// Removes the title with its files and puts it on the service's import exclusion list, so no list
    /// sync adds it again. A title the service no longer holds is only put on the exclusion list. True
    /// when the service held it.
    @discardableResult
    public func remove(_ title: ArrTitle) async throws -> Bool {
        guard title.kind == kind else { throw ArrError.notArr }
        switch title {
        case .movie(let tmdbID, let name, let year):
            var exclusion: [String: Any] = ["tmdbId": tmdbID, "movieTitle": name]
            if let year { exclusion["movieYear"] = year }
            return try await remove(
                lookup: "/api/v3/movie", idQuery: ("tmdbId", tmdbID), deletion: "/api/v3/movie/",
                exclusionFlag: "addImportExclusion", exclusionPath: "/api/v3/exclusions", exclusion: exclusion)
        case .series(let tvdbID, let name):
            return try await remove(
                lookup: "/api/v3/series", idQuery: ("tvdbId", tvdbID), deletion: "/api/v3/series/",
                exclusionFlag: "addImportListExclusion", exclusionPath: "/api/v3/importlistexclusion",
                exclusion: ["tvdbId": tvdbID, "title": name])
        }
    }

    private func remove(
        lookup: String, idQuery: (String, Int), deletion: String, exclusionFlag: String, exclusionPath: String,
        exclusion: [String: Any]
    ) async throws -> Bool {
        struct Row: Decodable { let id: Int }
        let found = try await send(.get, lookup, query: [URLQueryItem(name: idQuery.0, value: String(idQuery.1))])
        guard (200..<300).contains(found.status) else { throw failure(found) }
        guard let rows = try? JSONDecoder().decode([Row].self, from: found.body) else { throw ArrError.notArr }
        guard let id = rows.first?.id else {
            try await exclude(exclusionPath, exclusion)
            return false
        }
        let query = [URLQueryItem(name: "deleteFiles", value: "true"), URLQueryItem(name: exclusionFlag, value: "true")]
        let response = try await send(.delete, deletion + String(id), query: query, timeout: Self.removeTimeout)
        switch response.status {
        case 200..<300:
            return true
        case 404:
            // Gone between the lookup and the delete; the flag may not have been honoured.
            try await exclude(exclusionPath, exclusion)
            return false
        default:
            throw failure(response)
        }
    }

    /// Adds the exclusion; one that is there already is what was wanted.
    private func exclude(_ path: String, _ exclusion: [String: Any]) async throws {
        guard let body = try? JSONSerialization.data(withJSONObject: exclusion) else { throw ArrError.notArr }
        let response = try await send(.post, path, body: body)
        switch response.status {
        case 200..<300:
            return
        case 400 where String(decoding: response.body, as: UTF8.self).localizedCaseInsensitiveContains("already"):
            return
        default:
            throw failure(response)
        }
    }

    private func send(
        _ method: HTTPMethod, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
        timeout: TimeInterval = 20
    ) async throws -> PlexHTTPResponse {
        guard let url = PlexURL.make(base: config.address, path: path, query: query) else { throw ArrError.notArr }
        var headers = ["X-Api-Key": config.apiKey, "Accept": "application/json"]
        if body != nil { headers["Content-Type"] = "application/json" }
        do {
            return try await transport.send(
                PlexRequest(method: method, url: url, headers: headers, body: body, timeout: timeout, restrictToOrigin: true))
        } catch let failure as NetworkFailure {
            throw failure == .timedOut ? ArrError.timedOut : ArrError.unreachable
        }
    }

    private func failure(_ response: PlexHTTPResponse) -> ArrError {
        switch response.status {
        case 401, 403: .badKey
        case 404: .notArr
        default: .failed(status: response.status, message: Self.message(response.body))
        }
    }

    /// Sonarr and Radarr word an error as `{"message": …}`, or as a list of failed validations.
    private static func message(_ body: Data) -> String? {
        struct Message: Decodable { let message: String? }
        struct Validation: Decodable { let errorMessage: String? }
        if let text = (try? JSONDecoder().decode(Message.self, from: body))?.message { return text }
        return (try? JSONDecoder().decode([Validation].self, from: body))?.compactMap(\.errorMessage).first
    }
}
