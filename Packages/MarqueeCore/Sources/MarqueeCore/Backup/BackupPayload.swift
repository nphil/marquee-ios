import Foundation

/// One setting or secret in a backup. `store` names where the device keeps it (the iPhone's `defaults`,
/// `remote`, `secret` and `tv`; Android's own), `key` is its name there. `group` and `item` only say what
/// it belongs to, for the list shown before a restore.
public struct BackupEntry: Equatable, Sendable {
    public var store: String
    public var key: String
    public var group: BackupGroup
    public var item: String?
    public var value: BackupValue

    public init(store: String, key: String, group: BackupGroup, item: String? = nil, value: BackupValue) {
        self.store = store
        self.key = key
        self.group = group
        self.item = item
        self.value = value
    }

    /// Where it lives, for matching a backup's entries with the device's.
    public var id: String { "\(store)\u{0}\(key)" }
}

public enum BackupValue: Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case strings([String])
    case data(Data)
}

extension BackupEntry: Codable {
    private enum CodingKeys: String, CodingKey { case store, key, group, item, kind, value }

    /// An entry of a kind this version does not know.
    struct UnknownKind: Error {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        store = try c.decode(String.self, forKey: .store)
        key = try c.decode(String.self, forKey: .key)
        group = try c.decodeIfPresent(BackupGroup.self, forKey: .group) ?? .other
        item = try c.decodeIfPresent(String.self, forKey: .item)
        switch try c.decode(String.self, forKey: .kind) {
        case "bool": value = .bool(try c.decode(Bool.self, forKey: .value))
        case "int": value = .int(try c.decode(Int.self, forKey: .value))
        case "double": value = .double(try c.decode(Double.self, forKey: .value))
        case "string": value = .string(try c.decode(String.self, forKey: .value))
        case "strings": value = .strings(try c.decode([String].self, forKey: .value))
        case "data": value = .data(try c.decode(Data.self, forKey: .value))
        default: throw UnknownKind()
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(store, forKey: .store)
        try c.encode(key, forKey: .key)
        try c.encode(group, forKey: .group)
        try c.encodeIfPresent(item, forKey: .item)
        switch value {
        case .bool(let v): try c.encode("bool", forKey: .kind); try c.encode(v, forKey: .value)
        case .int(let v): try c.encode("int", forKey: .kind); try c.encode(v, forKey: .value)
        case .double(let v): try c.encode("double", forKey: .kind); try c.encode(v, forKey: .value)
        case .string(let v): try c.encode("string", forKey: .kind); try c.encode(v, forKey: .value)
        case .strings(let v): try c.encode("strings", forKey: .kind); try c.encode(v, forKey: .value)
        case .data(let v): try c.encode("data", forKey: .kind); try c.encode(v, forKey: .value)
        }
    }
}

/// What a group of settings is, for the list shown before a restore. Open-ended, so a newer app's group
/// still reads.
public struct BackupGroup: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let profiles = BackupGroup(rawValue: "profiles")
    public static let appearance = BackupGroup(rawValue: "appearance")
    public static let tabs = BackupGroup(rawValue: "tabs")
    public static let servers = BackupGroup(rawValue: "servers")
    public static let integrations = BackupGroup(rawValue: "integrations")
    public static let remote = BackupGroup(rawValue: "remote")
    public static let tvs = BackupGroup(rawValue: "tvs")
    public static let bigScreen = BackupGroup(rawValue: "bigScreen")
    public static let downloads = BackupGroup(rawValue: "downloads")
    public static let live = BackupGroup(rawValue: "live")
    public static let tracks = BackupGroup(rawValue: "tracks")
    public static let other = BackupGroup(rawValue: "other")

    static let order: [BackupGroup] = [
        .profiles, .appearance, .tabs, .servers, .integrations, .remote, .tvs, .bigScreen, .downloads, .live, .tracks, .other,
    ]

    public var title: String {
        switch self {
        case .profiles: "Profile settings"
        case .appearance: "Appearance and themes"
        case .tabs: "Tab layout"
        case .servers: "Server choice"
        case .integrations: "Integrations and their keys"
        case .remote: "Remote layout"
        case .tvs: "Paired TVs"
        case .bigScreen: "XR glasses and TV"
        case .downloads: "Download settings"
        case .live: "Live TV favourites and recents"
        case .tracks: "Remembered audio and subtitle choices"
        default: "Other settings"
        }
    }
}

/// What a backup holds. Everything in it is optional to read, so a newer app's additions do not stop an
/// older one from opening the file.
public struct BackupPayload: Codable, Equatable, Sendable {
    /// `ios` or `android`: whose `entries` these are.
    public var platform: String
    public var appVersion: String
    public var entries: [BackupEntry]
    /// The integrations in a form either platform can apply; how a backup moves between them.
    public var integrations: BackupIntegrations

    public init(platform: String, appVersion: String, entries: [BackupEntry], integrations: BackupIntegrations = [:]) {
        self.platform = platform
        self.appVersion = appVersion
        self.entries = entries
        self.integrations = integrations
    }

    private enum CodingKeys: String, CodingKey { case platform, appVersion, entries, integrations }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        platform = try c.decode(String.self, forKey: .platform)
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? ""
        entries = (try c.decodeIfPresent([Lossy<BackupEntry>].self, forKey: .entries) ?? []).compactMap(\.value)
        integrations = (try? c.decodeIfPresent([String: Lossy<BackupIntegration>].self, forKey: .integrations))?
            .compactMapValues(\.value) ?? [:]
    }
}

/// An element that decodes to nil instead of failing the whole list when it is of a kind this version
/// does not know.
struct Lossy<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Value.self)
    }
}

/// One integration in the form both apps share: where it answers, the key it takes and any options.
public struct BackupIntegration: Codable, Equatable, Sendable {
    public var address: String?
    public var secret: String?
    public var options: [String: String]

    public init(address: String? = nil, secret: String? = nil, options: [String: String] = [:]) {
        self.address = address
        self.secret = secret
        self.options = options
    }

    private enum CodingKeys: String, CodingKey { case address, secret, options }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        address = try c.decodeIfPresent(String.self, forKey: .address)
        secret = try c.decodeIfPresent(String.self, forKey: .secret)
        options = try c.decodeIfPresent([String: String].self, forKey: .options) ?? [:]
    }
}

/// Keyed by `BackupIntegrationName`.
public typealias BackupIntegrations = [String: BackupIntegration]

public enum BackupIntegrationName {
    public static let seerr = "seerr"
    public static let radarr = "radarr"
    public static let sonarr = "sonarr"
    public static let bazarr = "bazarr"
    public static let speechDock = "speechDock"
    public static let homeLabber = "homeLabber"
    public static let diagnostics = "diagnostics"
}

/// What a restore will change, in words: one line for each kind of setting, never a value.
public struct BackupContents: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public var title: String
        public var detail: String?
    }

    public var lines: [Line]

    /// The lines for what `payload` would change on a device of `platform`: all its entries on the same
    /// platform, only its integrations on the other.
    public init(_ payload: BackupPayload, restoringOn platform: String) {
        if payload.platform == platform {
            var lines: [Line] = []
            for group in BackupGroup.order {
                let entries = payload.entries.filter { $0.group == group || (group == .other && !BackupGroup.order.contains($0.group)) }
                guard !entries.isEmpty else { continue }
                lines.append(Line(title: group.title, detail: Self.detail(group, entries)))
            }
            self.lines = lines
        } else {
            let names = payload.integrations.keys.sorted().map(Self.integrationTitle)
            lines = names.isEmpty ? [] : [Line(title: BackupGroup.integrations.title, detail: names.joined(separator: ", "))]
        }
    }

    private static func detail(_ group: BackupGroup, _ entries: [BackupEntry]) -> String? {
        switch group {
        case .profiles: entries.count == 1 ? "1 profile" : "\(entries.count) profiles"
        case .tracks: entries.count == 1 ? "1 title" : "\(entries.count) titles"
        case .integrations, .tvs:
            Set(entries.compactMap(\.item)).sorted().joined(separator: ", ").nonEmpty
        default: nil
        }
    }

    static func integrationTitle(_ name: String) -> String {
        switch name {
        case BackupIntegrationName.seerr: "Seerr"
        case BackupIntegrationName.radarr: "Radarr"
        case BackupIntegrationName.sonarr: "Sonarr"
        case BackupIntegrationName.bazarr: "Bazarr"
        case BackupIntegrationName.speechDock: "SpeechDock"
        case BackupIntegrationName.homeLabber: "HomeLabber"
        case BackupIntegrationName.diagnostics: "Diagnostic Logs"
        default: name
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
