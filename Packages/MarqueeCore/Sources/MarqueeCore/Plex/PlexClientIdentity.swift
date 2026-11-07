import Foundation

/// The app as Plex sees it. Sent as headers on every request to plex.tv and to servers.
public struct PlexClientIdentity: Sendable, Hashable, Codable {
    /// Stable per install; see `storedClientIdentifier(in:key:)`.
    public var clientIdentifier: String
    public var product: String
    public var version: String
    public var platform: String
    public var platformVersion: String
    /// Hardware model, e.g. "iPhone18,1".
    public var device: String
    /// The name the owner gave the phone, shown in Plex's device list.
    public var deviceName: String

    public init(
        clientIdentifier: String,
        product: String = "Marquee",
        version: String,
        platform: String = "iOS",
        platformVersion: String,
        device: String,
        deviceName: String
    ) {
        self.clientIdentifier = clientIdentifier
        self.product = product
        self.version = version
        self.platform = platform
        self.platformVersion = platformVersion
        self.device = device
        self.deviceName = deviceName
    }

    /// Headers for one request. The token travels only here, never in a URL that
    /// could end up in a log or a cache key.
    public func headers(token: String?) -> [String: String] {
        var headers = [
            PlexHeader.clientIdentifier: clientIdentifier,
            PlexHeader.product: product,
            PlexHeader.version: version,
            PlexHeader.platform: platform,
            PlexHeader.platformVersion: platformVersion,
            PlexHeader.device: device,
            PlexHeader.deviceName: deviceName,
            "Accept": "application/json",
        ]
        if let token, !token.isEmpty {
            headers[PlexHeader.token] = token
        }
        return headers
    }

    public static let defaultIdentifierKey = "plex.clientIdentifier"

    /// The install's client identifier: generated once, then read back from `defaults`.
    /// Plex ties sign-ins and device entries to it, so it must survive launches.
    public static func storedClientIdentifier(
        in defaults: UserDefaults = .standard,
        key: String = defaultIdentifierKey
    ) -> String {
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        defaults.set(created, forKey: key)
        return created
    }
}

/// Plex header names.
public enum PlexHeader {
    public static let clientIdentifier = "X-Plex-Client-Identifier"
    public static let product = "X-Plex-Product"
    public static let version = "X-Plex-Version"
    public static let platform = "X-Plex-Platform"
    public static let platformVersion = "X-Plex-Platform-Version"
    public static let device = "X-Plex-Device"
    public static let deviceName = "X-Plex-Device-Name"
    public static let token = "X-Plex-Token"
    public static let containerStart = "X-Plex-Container-Start"
    public static let containerSize = "X-Plex-Container-Size"
    /// Ties requests to one playback session, e.g. timeline reports to their transcode.
    public static let sessionIdentifier = "X-Plex-Session-Identifier"
}

extension URL {
    /// This URL without any `X-Plex-Token` query item. Use it for cache keys and log lines.
    public var removingPlexToken: URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let items = components.percentEncodedQueryItems
        else { return self }
        let kept = items.filter { $0.name.caseInsensitiveCompare(PlexHeader.token) != .orderedSame }
        guard kept.count != items.count else { return self }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.url ?? self
    }
}
