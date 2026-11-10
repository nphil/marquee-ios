import Foundation

/// A Plex Media Server the account can use, from plex.tv's resource list.
///
/// `accessToken` is this user's token for the server. Encode a server only into the Keychain.
public struct PlexServer: Sendable, Hashable, Identifiable, Codable {
    public var id: String { clientIdentifier }
    public var name: String
    /// The server's machine identifier.
    public var clientIdentifier: String
    public var accessToken: String?
    public var isOwned: Bool
    /// Belongs to the user's Plex Home.
    public var isHome: Bool
    /// Owner's name for a server shared with the user.
    public var ownerName: String?
    /// plex.tv saw the server online recently.
    public var isPresent: Bool
    /// The server refuses plain-http connections.
    public var httpsRequired: Bool
    public var productVersion: String?
    public var connections: [PlexConnection]

    public init(
        name: String,
        clientIdentifier: String,
        accessToken: String? = nil,
        isOwned: Bool = true,
        isHome: Bool = false,
        ownerName: String? = nil,
        isPresent: Bool = true,
        httpsRequired: Bool = false,
        productVersion: String? = nil,
        connections: [PlexConnection]
    ) {
        self.name = name
        self.clientIdentifier = clientIdentifier
        self.accessToken = accessToken
        self.isOwned = isOwned
        self.isHome = isHome
        self.ownerName = ownerName
        self.isPresent = isPresent
        self.httpsRequired = httpsRequired
        self.productVersion = productVersion
        self.connections = connections
    }

    /// The user's own servers first, then the Plex Home's, then those friends share.
    var listOrder: Int { isOwned ? 0 : isHome ? 1 : 2 }
}

/// One address of a server.
public struct PlexConnection: Sendable, Hashable, Codable {
    public var uri: URL
    public var isLocal: Bool
    /// Routed through Plex's relay, which caps bandwidth.
    public var isRelay: Bool
    public var isIPv6: Bool

    public init(uri: URL, isLocal: Bool, isRelay: Bool = false, isIPv6: Bool = false) {
        self.uri = uri
        self.isLocal = isLocal
        self.isRelay = isRelay
        self.isIPv6 = isIPv6
    }

    public var isHTTPS: Bool { uri.scheme?.lowercased() == "https" }

    /// The IP the address points at: the host itself, or the one a plex.direct name spells in its first label
    /// ("81-2-3-4.<id>.plex.direct"); nil for any other name.
    public var ipAddress: String? {
        let host = (uri.host() ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasSuffix(".plex.direct"), let label = host.split(separator: ".").first {
            return label.replacingOccurrences(of: "-", with: isIPv6 ? ":" : ".")
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let isIPv4 = parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
        return isIPv4 || host.contains(":") ? host : nil
    }

    /// The address as a person reads it: the IP when there is one, far shorter than a plex.direct name; the
    /// port follows when it is not Plex's 32400.
    public var displayAddress: String {
        let host = ipAddress ?? (uri.host() ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard let port = uri.port, port != 32400 else { return host }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

/// One entry of `GET https://plex.tv/api/v2/resources`.
struct PlexResource: Decodable {
    let server: PlexServer?

    enum CodingKeys: String, CodingKey {
        case name, clientIdentifier, accessToken, owned, home, sourceTitle, presence, httpsRequired
        case productVersion, provides, connections
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let provides = (c.string(.provides) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard provides.contains("server"), let identifier = c.string(.clientIdentifier) else {
            server = nil
            return
        }
        let connections: [ResourceConnection] = c.list(.connections)
        server = PlexServer(
            name: c.string(.name) ?? "",
            clientIdentifier: identifier,
            accessToken: c.string(.accessToken),
            isOwned: c.bool(.owned) ?? false,
            isHome: c.bool(.home) ?? false,
            ownerName: c.string(.sourceTitle),
            isPresent: c.bool(.presence) ?? false,
            httpsRequired: c.bool(.httpsRequired) ?? false,
            productVersion: c.string(.productVersion),
            connections: connections.compactMap(\.connection)
        )
    }
}

private struct ResourceConnection: Decodable {
    let connection: PlexConnection?

    enum CodingKeys: String, CodingKey {
        case uri, local, relay, ipv6 = "IPv6"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let uri = c.string(.uri).flatMap(URL.init(string:)) else {
            connection = nil
            return
        }
        connection = PlexConnection(
            uri: uri,
            isLocal: c.bool(.local) ?? false,
            isRelay: c.bool(.relay) ?? false,
            isIPv6: c.bool(.ipv6) ?? false
        )
    }
}
