import MarqueeCore
import Observation
import SwiftUI
import UIKit

/// The Plex sign-in, the chosen server and the active Home profile (DESIGN §8.0). The account token
/// and the server list live in the Keychain, so a signed-in phone opens straight on its server and
/// checks plex.tv in the background.
@MainActor @Observable
final class AppSession {
    enum State: Equatable {
        case signedOut
        case signingIn
        case choosingServer([PlexServer])
        case ready
        case failed(PlexError)
    }

    private(set) var state: State = .signedOut
    /// The chosen server's library; set while `state` is `.ready`.
    private(set) var library: PlexLibrary?
    /// The active profile: the account itself or the Home profile switched to.
    private(set) var user: PlexHomeUser?
    private(set) var server: PlexServer?
    /// What the chosen server's owner allows and pays for; nothing until the server answers.
    private(set) var serverInfo = PlexServerInfo()
    /// Said on the sign-in screen after Delete All Local Data, until the next sign-in starts.
    private(set) var signedOutNotice: SignedOutNotice?
    /// plex.tv with the active profile's token; set while signed in.
    private(set) var plexTV: PlexTV?
    /// The account's own servers and its Plex Home's; servers friends share are left out.
    private(set) var servers: [PlexServer] = []
    private(set) var homeUsers: [PlexHomeUser] = []
    /// The code to type at plex.tv/link while the code sign-in waits.
    private(set) var linkCode: String?
    /// Counts network changes, so a visible server list knows to check its servers again.
    private(set) var networkChanges = 0
    /// Settings, in a sheet opened from Home's profile button.
    var showsSettings = false
    /// The full-screen player and whatever keeps playing in Picture in Picture.
    let player = PlayerCenter()
    /// The profile switcher sheet, opened from the Settings Account row.
    var showsProfileSwitcher = false
    /// The active profile's playback, audio and subtitle settings; every change is saved at once.
    var settings: ProfileSettings {
        get { profileSettings }
        set {
            profileSettings = newValue
            storage.setSettings(newValue, for: user?.uuid)
        }
    }
    /// SpeechDock (DESIGN §8.7 Integrations), off until enabled. A service address is not a viewing
    /// preference, so it is kept per iPhone rather than per profile.
    var speechDockEnabled: Bool {
        get { speechDockOn }
        set {
            speechDockOn = newValue
            storage.speechDockEnabled = newValue
        }
    }
    var speechDockAddress: String {
        get { speechDockText }
        set {
            speechDockText = newValue
            storage.speechDockAddress = newValue
        }
    }
    private var profileSettings = ProfileSettings()
    private var speechDockOn = false
    private var speechDockText = ""
    /// Bazarr (DESIGN §8.7 Integrations), kept per iPhone like SpeechDock.
    let bazarr: BazarrSettings

    /// Made again by Delete All Local Data, which removes the stored client identifier.
    private(set) var identity: PlexClientIdentity
    let transport: URLSessionTransport
    private let storage: SessionStorage
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private let signInBrowser = PlexSignInBrowser()
    /// plex.tv's approval page while a browser sign-in waits, so it can be opened again.
    private(set) var signInPage: URL?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var addressTask: Task<Void, Never>?
    @ObservationIgnored private var networkTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let localNetwork = LocalNetworkAccess()

    private static let forwardURL = URL(string: "marquee://signed-in")!

    init() {
        let storage: SessionStorage = FakePlex.isActive ? .uiTest() : .live()
        self.storage = storage
        identity = Self.identity(defaults: storage.defaults)
        let configuration = URLSessionConfiguration.default
        FakePlex.install(into: configuration)
        transport = URLSessionTransport(session: URLSession(configuration: configuration))
        bazarr = BazarrSettings(storage: storage, transport: transport)
        speechDockOn = storage.speechDockEnabled
        speechDockText = storage.speechDockAddress
        restore()
        watchNetwork()
        watchForeground()
        // The fake server is plain HTTP on the test host; no prompt should cover the UI tests' screens.
        if !FakePlex.isActive { localNetwork.request() }
    }

    // MARK: Sign-in

    /// Opens plex.tv's approval page and waits for the code to be approved there. The page closes
    /// itself once it is, whether or not plex.tv forwards back to the app.
    func signIn() {
        let tv = beginSignIn()
        signInTask = Task {
            await finishSignIn(tv) {
                let pin = try await tv.createPIN(strong: true)
                // The UI tests' fake plex.tv approves every code, and no browser can run there.
                if FakePlex.isActive { return try await tv.waitForToken(pin) }
                let url = tv.authURL(for: pin, forwardURL: Self.forwardURL)
                self.signInPage = url
                self.signInBrowser.open(url)
                defer {
                    self.signInBrowser.close()
                    self.signInPage = nil
                }
                return try await tv.waitForToken(pin)
            }
        }
    }

    /// Opens plex.tv's approval page again, for someone who closed it before approving.
    func reopenSignInPage() {
        if let signInPage { signInBrowser.open(signInPage) }
    }

    /// The fallback: a 4-character code typed at plex.tv/link on any device.
    func signInWithCode() {
        let tv = beginSignIn()
        signInTask = Task {
            await finishSignIn(tv) {
                let pin = try await tv.createPIN(strong: false)
                self.linkCode = pin.code
                return try await tv.waitForToken(pin)
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        linkCode = nil
        state = .signedOut
    }

    /// Checks the kept sign-in again after plex.tv could not be reached.
    func retry() {
        guard let tv = plexTV else {
            state = .signedOut
            return
        }
        state = .signingIn
        refreshTask?.cancel()
        refreshTask = Task { await refreshAccount(tv) }
    }

    /// Whether a failure can be retried with the kept sign-in, rather than needing a new one.
    var canRetry: Bool {
        plexTV != nil && state != .failed(.unauthorized)
    }

    // MARK: Servers

    func choose(_ server: PlexServer) {
        storage.serverID = server.id
        connect(to: server)
    }

    /// Asks plex.tv for the servers again, for the server list's Retry.
    func reloadServers() async {
        guard let tv = plexTV else { return }
        do {
            let found = try await tv.servers().filter(\.isOwnOrHome)
            storage.servers = found
            servers = found
            if case .choosingServer = state { state = .choosingServer(found) }
        } catch PlexError.unauthorized {
            state = .failed(.unauthorized)
        } catch {
            // The list keeps the servers it has.
        }
    }

    /// A fresh connection to `server` that probes its addresses, for the server list's connection labels.
    func probe(_ server: PlexServer) -> PlexServerConnection {
        PlexServerConnection(server: server, identity: identity, transport: transport)
    }

    // MARK: Profiles

    /// Switches to a Home profile. Throws `PlexError.profilePINRejected` for a wrong PIN. The chosen
    /// server stays when the profile can use it.
    func switchUser(_ profile: PlexHomeUser, pin: String?) async throws {
        guard let tv = plexTV else { return }
        let token = try await tv.switchHomeUser(profile, pin: pin)
        player.stopAll()
        let profileTV = makePlexTV(token: token)
        let found = try await profileTV.servers().filter(\.isOwnOrHome)
        storage.accountToken = token
        storage.servers = found
        plexTV = profileTV
        servers = found
        setUser(profile)
        if let id = server?.id, let same = found.first(where: { $0.id == id }) {
            connect(to: same)
        } else if found.count == 1, let only = found.first {
            choose(only)
        } else {
            library = nil
            server = nil
            state = .choosingServer(found)
        }
    }

    /// Forgets the sign-in: the token and the server list leave the Keychain. Settings and themes stay.
    func signOut() {
        for task in [signInTask, refreshTask, addressTask] { task?.cancel() }
        showsProfileSwitcher = false
        showsSettings = false
        player.stopAll()
        storage.clearSignIn()
        plexTV = nil
        library = nil
        server = nil
        serverInfo = PlexServerInfo()
        servers = []
        homeUsers = []
        linkCode = nil
        setUser(nil)
        state = .signedOut
    }

    /// Deleting a title from the server: the owner's own server, with "Allow media deletion" on in its
    /// settings, from the owner's profile. Anyone else gets 401 or 403.
    var canDeleteMedia: Bool {
        serverInfo.allowsMediaDeletion && server?.isOwned == true && isOwnerProfile
    }

    /// The signed-in account, or in a Plex Home its admin profile. An account without a Home may report
    /// itself as no admin.
    private var isOwnerProfile: Bool {
        guard let user else { return true }
        return user.isAdmin || !(homeUsers.contains(where: \.isAdmin) || user.isRestricted || user.isGuest)
    }

    struct SignedOutNotice: Equatable {
        var title: String
        var detail: String?
    }

    /// Signs out and removes everything the app keeps on the iPhone: the Keychain items, every saved
    /// preference (the client identifier among them, so the next sign-in is a new device), cached
    /// artwork, the guide cache and URL caches. Themes are reset by the caller, which owns them.
    func deleteAllLocalData() async {
        signOut()
        storage.eraseAll()
        identity = Self.identity(defaults: storage.defaults)
        URLCache.shared.removeAllCachedResponses()
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        var removedAll = await ImagePipeline.shared.removeAll()
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let temporary = FileManager.default.temporaryDirectory
        for folder in [caches, temporary] {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            // The artwork folder stays for the pipeline to write into; its files went above.
            for file in files where file.lastPathComponent != "Artwork" && (try? FileManager.default.removeItem(at: file)) == nil {
                removedAll = false
            }
        }
        signedOutNotice = removedAll
            ? SignedOutNotice(title: "Local data deleted")
            : SignedOutNotice(
                title: "Signed out, and most local data deleted",
                detail: "Some files could not be removed. Deleting the app removes the rest."
            )
    }

    func play(item: PlexMetadata, mediaIndex: Int = 0, fromStart: Bool = false) {
        player.play(PlaybackRequest(item: item, mediaIndex: mediaIndex, fromStart: fromStart), session: self)
    }

    /// The audio and subtitle picks remembered for the item's show (or the movie) on this server and profile.
    func trackMemory(for item: PlexMetadata) -> TrackMemory? {
        storage.trackMemory(forKey: trackKey(for: item))
    }

    func remember(_ memory: TrackMemory, for item: PlexMetadata) {
        storage.setTrackMemory(memory, forKey: trackKey(for: item))
    }

    private func trackKey(for item: PlexMetadata) -> String {
        TrackMemory.storageKey(server: server?.id ?? "", profile: user?.uuid ?? "", item: item)
    }

    // MARK: Private

    private enum ServerPick {
        /// The remembered server, or the only one.
        case remembered
        /// The first server; UI-test launches only.
        case first
        /// Always the list; UI-test launches only.
        case list
    }

    private static func identity(defaults: UserDefaults) -> PlexClientIdentity {
        let device = UIDevice.current
        return PlexClientIdentity(
            clientIdentifier: PlexClientIdentity.storedClientIdentifier(in: defaults),
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            platformVersion: device.systemVersion,
            device: device.model,
            deviceName: device.name
        )
    }

    private func makePlexTV(token: String?) -> PlexTV {
        PlexTV(http: PlexHTTPClient(identity: identity, token: token, transport: transport))
    }

    private func restore() {
        if FakePlex.isActive {
            restoreUITest()
            return
        }
        guard let token = storage.accountToken else { return }
        let tv = makePlexTV(token: token)
        plexTV = tv
        servers = storage.servers
        setUser(storage.profile)
        if let server = rememberedServer(in: servers) {
            connect(to: server)
        } else {
            state = servers.isEmpty ? .signingIn : .choosingServer(servers)
        }
        refreshTask = Task { await refreshAccount(tv) }
    }

    /// UI-test launches start signed out unless `-marquee.fakeSignedIn YES` (open on the first server)
    /// or `-marquee.fakeServerList YES` (open on the server list) is passed. `-marquee.uitest.bazarr`
    /// with an address saves a Bazarr there, answered by the fake Plex's `bazarr` fixtures.
    private func restoreUITest() {
        let arguments = UserDefaults.standard
        if let address = arguments.string(forKey: "marquee.uitest.bazarr").flatMap(URL.init(string:)) {
            bazarr.save(BazarrConfig(address: address, apiKey: "fake"))
        }
        let pick: ServerPick
        if arguments.bool(forKey: "marquee.fakeSignedIn") {
            pick = .first
        } else if arguments.bool(forKey: "marquee.fakeServerList") {
            pick = .list
        } else {
            return
        }
        state = .signingIn
        let token = "fake-account-token"
        let tv = makePlexTV(token: token)
        signInTask = Task { await completeSignIn(token: token, tv: tv, pick: pick) }
    }

    /// Cancels any sign-in under way and shows the waiting state. Returns plex.tv without a token.
    private func beginSignIn() -> PlexTV {
        signInTask?.cancel()
        refreshTask?.cancel()
        linkCode = nil
        signedOutNotice = nil
        state = .signingIn
        return makePlexTV(token: nil)
    }

    /// Runs `obtainToken`, then loads the account with the token it returns. Nil means the browser
    /// closed without an approval.
    private func finishSignIn(_ tv: PlexTV, obtainToken: () async throws -> String?) async {
        do {
            guard let token = try await obtainToken() else {
                state = .signedOut
                return
            }
            await tv.http.setToken(token)
            await completeSignIn(token: token, tv: tv, pick: .remembered)
        } catch is CancellationError {
            // cancelSignIn() already reset the state.
        } catch {
            linkCode = nil
            state = .failed(error as? PlexError ?? .unreachable(.other))
        }
    }

    private func completeSignIn(token: String, tv: PlexTV, pick: ServerPick) async {
        do {
            let found = try await tv.servers().filter(\.isOwnOrHome)
            let account = try? await tv.account()
            let profiles = (try? await tv.homeUsers()) ?? []
            guard !Task.isCancelled else { return }
            storage.accountToken = token
            storage.servers = found
            plexTV = tv
            servers = found
            homeUsers = profiles
            linkCode = nil
            setUser(account ?? profiles.first(where: \.isAdmin))
            switch pick {
            case .remembered: show(found)
            case .first: if let first = found.first { choose(first) } else { state = .choosingServer(found) }
            case .list: state = .choosingServer(found)
            }
        } catch is CancellationError {
        } catch {
            linkCode = nil
            state = .failed(error as? PlexError ?? .unreachable(.other))
        }
    }

    /// Brings a kept sign-in up to date: the servers (their tokens can change), the profile and the Home.
    private func refreshAccount(_ tv: PlexTV) async {
        do {
            let found = try await tv.servers().filter(\.isOwnOrHome)
            let account = try? await tv.account()
            let profiles = try? await tv.homeUsers()
            guard !Task.isCancelled else { return }
            storage.servers = found
            servers = found
            if let account { setUser(account) }
            if let profiles { homeUsers = profiles }
            switch state {
            case .ready:
                // The open screens keep their library unless the server's token changed.
                if let server, let fresh = found.first(where: { $0.id == server.id }), fresh.accessToken != server.accessToken {
                    connect(to: fresh)
                }
            case .signingIn, .choosingServer:
                show(found)
            case .signedOut, .failed:
                break
            }
        } catch is CancellationError {
        } catch PlexError.unauthorized {
            state = .failed(.unauthorized)
        } catch {
            // Offline: the kept servers stay usable. Only a launch with nothing kept reports it.
            if state == .signingIn { state = .failed(error as? PlexError ?? .unreachable(.other)) }
        }
    }

    private func show(_ found: [PlexServer]) {
        if let server = rememberedServer(in: found) {
            choose(server)
        } else {
            state = .choosingServer(found)
        }
    }

    private func rememberedServer(in list: [PlexServer]) -> PlexServer? {
        if let id = storage.serverID, let server = list.first(where: { $0.id == id }) { return server }
        return list.count == 1 ? list.first : nil
    }

    private func connect(to server: PlexServer) {
        let library = PlexLibrary(server: server, identity: identity, transport: transport, rememberedURI: storage.address(for: server.id))
        self.server = server
        self.library = library
        serverInfo = PlexServerInfo()
        state = .ready
        addressTask?.cancel()
        addressTask = Task {
            await keepAddress(of: library.connection, reprobe: false)
            await loadServerInfo(from: library)
        }
        #if DEBUG
        playForUITest(library)
        #endif
    }

    #if DEBUG
    /// UI tests open the player straight on an item, paused where they want it, against the fake server.
    /// `marquee.uitest.introSkipDelay` lengthens the intro countdown for this launch only, so a test can
    /// wait for the controls to hide before it taps the offer.
    private func playForUITest(_ library: PlexLibrary) {
        let defaults = UserDefaults.standard
        guard FakePlex.isActive, let key = defaults.string(forKey: "marquee.uitest.play") else { return }
        Task {
            guard let item = try? await library.metadata(key) else { return }
            let delay = defaults.integer(forKey: "marquee.uitest.introSkipDelay")
            if delay > 0 { profileSettings.introSkipDelay = delay }
            let time = defaults.double(forKey: "marquee.uitest.playerTime")
            let request = PlaybackRequest(item: item, startAt: time > 0 ? time : nil, startsPaused: defaults.bool(forKey: "marquee.uitest.paused"))
            player.play(request, session: self)
            player.active?.showsStats = defaults.bool(forKey: "marquee.uitest.stats")
        }
    }
    #endif

    /// Finds the server's address now, so the first screen does not wait for it, and keeps the one
    /// that answered for the next launch.
    private func keepAddress(of connection: PlexServerConnection, reprobe: Bool) async {
        let found: PlexConnection?
        if reprobe {
            found = try? await connection.refresh()
        } else {
            found = try? await connection.connection()
        }
        guard let found, !Task.isCancelled else { return }
        storage.setAddress(found.uri, for: connection.server.id)
    }

    private func loadServerInfo(from library: PlexLibrary) async {
        guard let info = try? await library.serverInfo(), !Task.isCancelled else { return }
        serverInfo = info
    }

    /// Loads the profile's own settings along with it.
    private func setUser(_ profile: PlexHomeUser?) {
        user = profile
        storage.profile = profile
        profileSettings = storage.settings(for: profile?.uuid)
    }

    private func watchNetwork() {
        networkTask = Task { [weak self] in
            var last: NetworkPath?
            for await path in NetworkPath.updates() {
                let changed = last.map { $0 != path } ?? false
                last = path
                if changed, path.isConnected { self?.networkChanged() }
            }
        }
    }

    /// A phone that comes home should move back to the LAN address, and one that leaves to a remote one.
    private func networkChanged() {
        networkChanges += 1
        guard let connection = library?.connection else { return }
        addressTask?.cancel()
        addressTask = Task { await keepAddress(of: connection, reprobe: true) }
    }

    /// A remote address may have won while iOS asked for Local Network access, or while a VPN was on;
    /// coming back to the foreground, which is also when that prompt closes, is when either changes.
    private func watchForeground() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferLocalAddress() }
        }
    }

    private func preferLocalAddress() {
        guard let connection = library?.connection else { return }
        Task {
            guard let found = await connection.preferLocal() else { return }
            storage.setAddress(found.uri, for: connection.server.id)
        }
    }
}
