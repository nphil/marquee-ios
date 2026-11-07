import Foundation
import MarqueeCore

/// Where the sign-in is kept between launches: the account token and the server list (which carries
/// each server's access token) in the Keychain; the chosen server, the active profile, the last working
/// addresses, each profile's settings and the device's integrations in UserDefaults. UI-test launches
/// keep secrets in memory and start from an emptied defaults suite.
@MainActor
final class SessionStorage {
    let defaults: UserDefaults
    /// Nil for UI-test launches, which keep secrets in `memory` instead.
    private let keychain: KeychainStore?
    private var memory: [String: Data] = [:]

    private enum Key {
        static let token = "plex.accountToken"
        static let servers = "plex.servers"
        static let serverID = "marquee.server.id"
        static let profile = "marquee.profile"
        static let addressPrefix = "marquee.server.address."
        static let settingsPrefix = "marquee.settings."
        static let speechDockEnabled = "marquee.speechDock.enabled"
        static let speechDockAddress = "marquee.speechDock.address"
    }

    private init(defaults: UserDefaults, keychain: KeychainStore?) {
        self.defaults = defaults
        self.keychain = keychain
    }

    static func live() -> SessionStorage {
        SessionStorage(defaults: .standard, keychain: KeychainStore())
    }

    /// Settings saved by an earlier test must not leak into the next screenshot, so the suite is wiped.
    static func uiTest() -> SessionStorage {
        let suite = "com.nphil.marquee.uitest"
        // Nil only for the app's own bundle identifier or the global domain.
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SessionStorage(defaults: defaults, keychain: nil)
    }

    var accountToken: String? {
        get { secret(Key.token).map { String(decoding: $0, as: UTF8.self) } }
        set { setSecret(newValue.map { Data($0.utf8) }, for: Key.token) }
    }

    var servers: [PlexServer] {
        get { secret(Key.servers).flatMap { try? JSONDecoder().decode([PlexServer].self, from: $0) } ?? [] }
        set { setSecret(try? JSONEncoder().encode(newValue), for: Key.servers) }
    }

    var serverID: String? {
        get { defaults.string(forKey: Key.serverID) }
        set { defaults.set(newValue, forKey: Key.serverID) }
    }

    var profile: PlexHomeUser? {
        get { defaults.data(forKey: Key.profile).flatMap { try? JSONDecoder().decode(PlexHomeUser.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.profile) }
    }

    /// The address that answered last time, tried alone first on the next launch.
    func address(for serverID: String) -> URL? {
        defaults.url(forKey: Key.addressPrefix + serverID)
    }

    func setAddress(_ uri: URL, for serverID: String) {
        defaults.set(uri, forKey: Key.addressPrefix + serverID)
    }

    /// A profile's settings, keyed by its Plex uuid; defaults for a profile that has none.
    func settings(for profile: String?) -> ProfileSettings {
        defaults.data(forKey: Key.settingsPrefix + (profile ?? ""))
            .flatMap { try? JSONDecoder().decode(ProfileSettings.self, from: $0) } ?? ProfileSettings()
    }

    func setSettings(_ settings: ProfileSettings, for profile: String?) {
        defaults.set(try? JSONEncoder().encode(settings), forKey: Key.settingsPrefix + (profile ?? ""))
    }

    var speechDockEnabled: Bool {
        get { defaults.bool(forKey: Key.speechDockEnabled) }
        set { defaults.set(newValue, forKey: Key.speechDockEnabled) }
    }

    var speechDockAddress: String {
        get { defaults.string(forKey: Key.speechDockAddress) ?? "" }
        set { defaults.set(newValue, forKey: Key.speechDockAddress) }
    }

    /// Sign-out: the token and servers leave the Keychain; settings and themes stay.
    func clearSignIn() {
        accountToken = nil
        setSecret(nil, for: Key.servers)
        serverID = nil
        profile = nil
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Key.addressPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private func secret(_ key: String) -> Data? {
        guard let keychain else { return memory[key] }
        return try? keychain.data(for: key)
    }

    private func setSecret(_ data: Data?, for key: String) {
        guard let keychain else {
            memory[key] = data
            return
        }
        try? keychain.setData(data, for: key)
    }
}
