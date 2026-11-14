import Foundation
import MarqueeCore

/// Where the sign-in is kept between launches: the account token and the server list (which carries
/// each server's access token) in the Keychain; the chosen server, the active profile, the last working
/// addresses, each profile's settings and the device's integrations in UserDefaults. UI-test launches
/// keep secrets in memory and start from an emptied defaults suite.
@MainActor
final class SessionStorage {
    let defaults: UserDefaults
    /// The defaults domain Delete All Local Data empties: the app's own, or the UI tests' suite.
    private let domain: String
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
        static let speechDockAddress = "marquee.speechDock.address"
        static let bazarrAddress = "marquee.bazarr.address"
        static let bazarrKey = "marquee.bazarr.key"
        static let seerrAddress = "marquee.seerr.address"
        static let seerrKey = "marquee.seerr.key"
        static let seerrSession = "marquee.seerr.session"
        static let seerrPulsarr = "marquee.seerr.pulsarr"
        static let castEnabled = "marquee.cast.enabled"
        static let remoteEnabled = "marquee.remote.enabled"
        static let remoteAccess = "marquee.remote.access"
        static let glassesEnabled = "marquee.glasses.enabled"
        static let glassesUse = "marquee.glasses.use"
        static let glassesTilt = "marquee.glasses.tilt"
        static let glassesKind = "marquee.glasses.kind"
        static let glassesDisplays = "marquee.glasses.displays"
        static let tracksPrefix = "marquee."
    }

    private init(defaults: UserDefaults, domain: String, keychain: KeychainStore?) {
        self.defaults = defaults
        self.domain = domain
        self.keychain = keychain
    }

    static func live() -> SessionStorage {
        SessionStorage(defaults: .standard, domain: Bundle.main.bundleIdentifier ?? "", keychain: KeychainStore())
    }

    /// Settings saved by an earlier test must not leak into the next screenshot, so the suite is wiped.
    static func uiTest() -> SessionStorage {
        let suite = "com.nphil.marquee.uitest"
        // Nil only for the app's own bundle identifier or the global domain.
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SessionStorage(defaults: defaults, domain: suite, keychain: nil)
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

    /// Each profile's settings, keyed by its Plex uuid.
    var profileSettings: ProfileSettingsStore<ProfileSettings> {
        ProfileSettingsStore(prefix: Key.settingsPrefix, blobs: DefaultsBlobs(defaults: defaults), defaults: { ProfileSettings() })
    }

    /// The audio and subtitle picks remembered for a show or movie, under `TrackMemory.storageKey`.
    func trackMemory(forKey key: String) -> TrackMemory? {
        defaults.data(forKey: Key.tracksPrefix + key).flatMap { try? JSONDecoder().decode(TrackMemory.self, from: $0) }
    }

    func setTrackMemory(_ memory: TrackMemory, forKey key: String) {
        defaults.set(try? JSONEncoder().encode(memory), forKey: Key.tracksPrefix + key)
    }

    var speechDockAddress: String {
        get { defaults.string(forKey: Key.speechDockAddress) ?? "" }
        set { defaults.set(newValue, forKey: Key.speechDockAddress) }
    }

    /// The Chromecast plugin is on; kept per iPhone, as the receivers are on its network.
    var castEnabled: Bool {
        get { defaults.bool(forKey: Key.castEnabled) }
        set { defaults.set(newValue, forKey: Key.castEnabled) }
    }

    /// Bazarr's address and API key; the key is a secret like the Plex sign-in. Kept through sign-out.
    var bazarr: BazarrConfig? {
        get {
            guard let address = defaults.url(forKey: Key.bazarrAddress), let key = secret(Key.bazarrKey) else { return nil }
            return BazarrConfig(address: address, apiKey: String(decoding: key, as: UTF8.self))
        }
        set {
            defaults.set(newValue?.address, forKey: Key.bazarrAddress)
            setSecret(newValue.map { Data($0.apiKey.utf8) }, for: Key.bazarrKey)
        }
    }

    /// Seerr's address, and its API key when it signs in with one rather than the Plex profile; the key
    /// is a secret like Bazarr's. Kept through sign-out.
    var seerr: SeerrConfig? {
        get {
            guard let address = defaults.url(forKey: Key.seerrAddress) else { return nil }
            let key = secret(Key.seerrKey).map { String(decoding: $0, as: UTF8.self) }
            return SeerrConfig(address: address, auth: key.map { .apiKey($0) } ?? .plex)
        }
        set {
            defaults.set(newValue?.address, forKey: Key.seerrAddress)
            var key: String?
            if case .apiKey(let value) = newValue?.auth { key = value }
            setSecret(key.map { Data($0.utf8) }, for: Key.seerrKey)
        }
    }

    /// Seerr's cookie from the last sign-in with Plex, so a launch need not sign in again.
    var seerrSession: SeerrSession? {
        get { secret(Key.seerrSession).flatMap { try? JSONDecoder().decode(SeerrSession.self, from: $0) } }
        set { setSecret(newValue.flatMap { try? JSONEncoder().encode($0) }, for: Key.seerrSession) }
    }

    /// Pulsarr also requests what goes on a Plex Watchlist.
    var seerrPulsarr: Bool {
        get { defaults.bool(forKey: Key.seerrPulsarr) }
        set { defaults.set(newValue, forKey: Key.seerrPulsarr) }
    }

    /// Whether the LumaTV remote is on. Its paired TVs and settings are LumaRemoteKit's own.
    var remoteEnabled: Bool {
        get { defaults.bool(forKey: Key.remoteEnabled) }
        set { defaults.set(newValue, forKey: Key.remoteEnabled) }
    }

    var remoteAccess: RemoteAccess {
        get { defaults.string(forKey: Key.remoteAccess).flatMap(RemoteAccess.init(rawValue:)) ?? .miniBar }
        set { defaults.set(newValue.rawValue, forKey: Key.remoteAccess) }
    }

    /// The big-screen plugin (XR glasses and TVs) is on, what a connected display is for, which kind a
    /// display not told apart yet is taken for, the answers kept per display, and whether tilting the phone
    /// moves things while the thumb holds. Kept per iPhone, like the display.
    var glassesEnabled: Bool {
        get { defaults.bool(forKey: Key.glassesEnabled) }
        set { defaults.set(newValue, forKey: Key.glassesEnabled) }
    }

    var glassesUse: BigScreenUse {
        get { defaults.string(forKey: Key.glassesUse).flatMap(BigScreenUse.init(rawValue:)) ?? .ask }
        set { defaults.set(newValue.rawValue, forKey: Key.glassesUse) }
    }

    /// Glasses until a display is told apart, as before TVs were supported.
    var glassesKind: DisplayKind {
        get { defaults.string(forKey: Key.glassesKind).flatMap(DisplayKind.init(rawValue:)) ?? .glasses }
        set { defaults.set(newValue.rawValue, forKey: Key.glassesKind) }
    }

    var glassesDisplays: DisplayMemory {
        get { defaults.data(forKey: Key.glassesDisplays).flatMap { try? JSONDecoder().decode(DisplayMemory.self, from: $0) } ?? DisplayMemory() }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.glassesDisplays) }
    }

    var glassesTilt: Bool {
        get { defaults.object(forKey: Key.glassesTilt) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.glassesTilt) }
    }

    /// Sign-out: the token, the servers and the Seerr session made with the token leave the Keychain;
    /// settings and themes stay.
    func clearSignIn() {
        accountToken = nil
        setSecret(nil, for: Key.servers)
        serverID = nil
        seerrSession = nil
        profile = nil
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Key.addressPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Delete All Local Data: the Keychain items and every saved preference, including the client
    /// identifier, each profile's settings, remembered tracks, themes and Live TV lists.
    func eraseAll() {
        clearSignIn()
        seerr = nil
        defaults.removePersistentDomain(forName: domain)
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

private final class DefaultsBlobs: SettingsBlobStore {
    let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }
    func blob(forKey key: String) -> Data? { defaults.data(forKey: key) }
    func setBlob(_ data: Data?, forKey key: String) { defaults.set(data, forKey: key) }
}
