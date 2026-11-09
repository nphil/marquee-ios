import Foundation

/// Where settings blobs are kept: `UserDefaults` in the app, a dictionary in tests.
public protocol SettingsBlobStore: AnyObject {
    func blob(forKey key: String) -> Data?
    func setBlob(_ data: Data?, forKey key: String)
}

/// One profile's settings, saved and read under the profile's Plex uuid. The empty uuid is the profile
/// nobody has signed in as yet.
public struct ProfileSettingsStore<Settings: Codable> {
    private let prefix: String
    private let blobs: any SettingsBlobStore
    private let defaults: () -> Settings

    public init(prefix: String, blobs: any SettingsBlobStore, defaults: @escaping () -> Settings) {
        self.prefix = prefix
        self.blobs = blobs
        self.defaults = defaults
    }

    /// The settings of `profile`. A profile with none yet takes those of `previous`, the key the same
    /// person was known under: plex.tv can name a profile differently from the list the app kept, and
    /// settings changed before the profile was known sit under the empty uuid. Taking the empty uuid's
    /// settings moves them, so a second profile does not inherit them too.
    public func load(profile: String, inheriting previous: String? = nil) -> Settings {
        if let stored = stored(profile) { return stored }
        guard let previous, previous != profile, let inherited = stored(previous) else { return defaults() }
        save(inherited, profile: profile)
        if previous.isEmpty { blobs.setBlob(nil, forKey: prefix + previous) }
        return inherited
    }

    public func save(_ settings: Settings, profile: String) {
        blobs.setBlob(try? JSONEncoder().encode(settings), forKey: prefix + profile)
    }

    private func stored(_ profile: String) -> Settings? {
        blobs.blob(forKey: prefix + profile).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
    }
}
