import Foundation
import LumaRemoteCore
import MarqueeCore
import Network
import SwiftUI

/// Linked phones (DESIGN §8.10): two iPhones with Marquee, linked once by a code one shows and the other
/// scans, find each other on the same network from then on, and either one can be the remote for what
/// the other drives: its big screen through the eyes-free remote, or its own player through a few
/// buttons. Off until Settings › Linked Phones turns it on, and on the network only while Marquee is in
/// front with a phone to find or a code on show.
@MainActor @Observable
final class PhoneLink {
    /// A connected linked phone, and what it last said it shows.
    struct Presence {
        var status: LinkStatus?
        /// When `status` came, so a playing title's time runs on from it.
        var statusAt = Date.now
    }

    /// How a pairing ended, for the screen that started it.
    enum Outcome: Equatable {
        case linked(String)
        case failed(String)
    }

    private(set) var isEnabled: Bool
    /// The name set in Settings, empty for the default.
    private(set) var customName: String
    private(set) var phones: [LinkedPhone] = []
    private(set) var presence: [LinkID: Presence] = [:]
    /// The code Show Link Code shows, while it shows, and how its pairing went.
    private(set) var invite: LinkInvite?
    private(set) var inviteOutcome: Outcome?
    /// The phone this one is the remote for, while that remote shows.
    private(set) var controlling: LinkID?
    /// Marquee may not use the local network, so no phone can be found.
    private(set) var isDenied = false

    /// A handshake, or the scanning phone's whole pairing, that takes longer has failed.
    private static let deadline: Duration = .seconds(6)
    private static let pairingDeadline: Duration = .seconds(10)
    /// Every connected phone sends at least every `LinkStatusPacer.refresh`; three missed means it went.
    private static let silence = 3 * LinkStatusPacer.refresh
    private static let tickInterval: Duration = .milliseconds(250)
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// An open session with a linked phone.
    private struct Connection {
        let wire: any LinkWire
        /// The phone that called, which decides which of two crossing calls stays.
        let caller: LinkID
        /// Tells this connection's late events from a newer one's.
        let token: Int
        var heardAt: TimeInterval
        var pacer = LinkStatusPacer()
        var reader: Task<Void, Never>?
    }

    @ObservationIgnored private let storage: SessionStorage
    @ObservationIgnored private let store: LinkStore
    @ObservationIgnored private weak var session: AppSession?
    @ObservationIgnored private weak var themeStore: ThemeStore?
    /// This phone's link id, once the Keychain has been read.
    @ObservationIgnored private var id: LinkID?
    @ObservationIgnored private var foreground = false
    @ObservationIgnored private var running = false
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var restart: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// Linked phones Bonjour sees on this network now.
    @ObservationIgnored private var nearby: Set<LinkID> = []
    @ObservationIgnored private var links: [LinkID: Connection] = [:]
    @ObservationIgnored private var calls: [LinkID: Task<Void, Never>] = [:]
    @ObservationIgnored private var failures: [LinkID: Int] = [:]
    @ObservationIgnored private var tokens = 0
    /// The code on show already linked a phone; each code links one.
    @ObservationIgnored private var inviteSpent = false
    @ObservationIgnored private let window = LinkControllerWindow()
    /// Held here: the remote's surface holds it weakly.
    @ObservationIgnored private var remote: LinkRemote?
    #if DEBUG
    @ObservationIgnored private var fake: FakeLinkPhone?
    /// The code Scan Link Code reads without a camera in UI tests.
    @ObservationIgnored private(set) var simulatedScan: LinkInvite?
    #endif

    init(storage: SessionStorage, inMemory: Bool) {
        self.storage = storage
        store = LinkStore(inMemory: inMemory)
        isEnabled = storage.linkEnabled
        customName = storage.linkName
    }

    /// What the other phones call this one: the name set in Settings, else the profile's iPhone.
    var name: String {
        if !customName.isEmpty { return customName }
        let profile = session?.user.map { LinkName.clean("\($0.title)’s iPhone") } ?? ""
        return profile.isEmpty ? "iPhone" : profile
    }

    func linkedPhone(_ id: LinkID) -> LinkedPhone? {
        phones.first { $0.id == id }
    }

    /// The linked phone Home offers to control: the first connected one driving a big screen or playing.
    var controllable: LinkedPhone? {
        guard isEnabled else { return nil }
        return phones.first { presence[$0.id]?.status?.isControllable == true }
    }

    // MARK: Settings

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        storage.linkEnabled = enabled
        if !enabled {
            invite = nil
            stopControlling()
        }
        refresh()
    }

    /// A new name, which connected phones hear at once.
    func setName(_ name: String) {
        let cleaned = LinkName.clean(name)
        guard cleaned != customName else { return }
        customName = cleaned
        storage.linkName = cleaned
        for connection in links.values { connection.wire.send(.hello(name: self.name)) }
    }

    /// Marquee came to the front or left it; iOS stops a background app's listener anyway.
    func setForeground(_ foreground: Bool, session: AppSession, themeStore: ThemeStore) {
        self.session = session
        self.themeStore = themeStore
        self.foreground = foreground
        refresh()
    }

    /// Unlinks a phone on both sides: a connected one hears it now; one out of reach keeps listing this
    /// phone, which no longer answers it, until it is unlinked there too.
    func unlink(_ peer: LinkID) {
        links[peer]?.wire.send(.unlink)
        forget(peer)
    }

    /// Delete All Local Data: this phone's id and links. Phones in reach unlink it too; the others list it
    /// until they unlink it.
    func eraseAll() {
        for connection in links.values { connection.wire.send(.unlink) }
        stopControlling()
        invite = nil
        inviteOutcome = nil
        stop()
        store.erase()
        id = nil
        phones = []
        customName = ""
        setEnabled(false)
    }

    // MARK: Pairing

    /// Opens the code for Show Link Code. It lasts while it shows and links one phone.
    func openInvite() {
        if id == nil { load() }
        guard let id else {
            inviteOutcome = .failed("Marquee couldn’t read its keys. Unlock the iPhone and try again.")
            return
        }
        invite = LinkInvite(id: id, name: name)
        inviteOutcome = nil
        inviteSpent = false
        refresh()
    }

    func closeInvite() {
        invite = nil
        inviteOutcome = nil
        refresh()
    }

    /// Links with the phone whose code was scanned: this phone calls it, both prove they hold the code's
    /// secret, and each adds a share to the key they keep.
    func join(_ invite: LinkInvite) async -> Outcome {
        if id == nil { load() }
        guard let me = id else { return .failed("Marquee couldn’t read its keys. Unlock the iPhone and try again.") }
        guard invite.id != me else { return .failed("That is this iPhone’s own code. Scan it with the other iPhone.") }
        #if DEBUG
        if simulatedScan == invite {
            add(LinkedPhone(id: invite.id, name: invite.name, key: LinkKeys.randomBytes(LinkKeys.keyLength), linkedAt: .now))
            return .linked(invite.name)
        }
        #endif
        let mine = LinkIntroduction(id: me, name: name, share: LinkKeys.randomBytes(LinkKeys.shareLength))
        let failure = DialFailure()
        let stream = LinkTransport.dial(invite.id, failure: failure)
        let preamble = LinkPreamble(mode: .pairing, caller: me)
        let psk = LinkKeys.pairingKey(secret: invite.secret)
        let inviter = try? await withDeadline(Self.pairingDeadline, onTimeout: { stream.abort() }) {
            let channel = try await LinkTransport.call(stream, preamble: preamble, psk: psk)
            defer { channel.close() }
            channel.send(.join(mine))
            guard case .welcome(let inviter) = try await channel.receive(), inviter.id == invite.id,
                  inviter.share.count == LinkKeys.shareLength else { throw StreamError.closed }
            return inviter
        }
        guard let inviter else {
            return .failed(await LinkTransport.unreachableReason(invite.name, failure: failure))
        }
        let key = LinkKeys.linkKey(secret: invite.secret, inviter: inviter.id, inviterShare: inviter.share, guest: me, guestShare: mine.share)
        let named = LinkName.clean(inviter.name)
        let phone = LinkedPhone(id: inviter.id, name: named.isEmpty ? invite.name : named, key: key, linkedAt: .now)
        add(phone)
        return .linked(phone.name)
    }

    /// The other half of pairing, on the phone showing the code.
    private func answerPairing(_ stream: TCPStream, preamble: LinkPreamble) async {
        guard let invite, !inviteSpent, let me = id else { return stream.abort() }
        let psk = LinkKeys.pairingKey(secret: invite.secret)
        let channel = try? await withDeadline(Self.deadline, onTimeout: { stream.abort() }) {
            try await LinkTransport.answer(stream, preamble: preamble, psk: psk)
        }
        guard let channel else { return stream.abort() }
        // Only a phone that read the code gets here, and only the first one links.
        guard self.invite == invite, !inviteSpent else { return channel.close() }
        inviteSpent = true
        let mine = LinkIntroduction(id: me, name: name, share: LinkKeys.randomBytes(LinkKeys.shareLength))
        let guest = try? await withDeadline(Self.deadline, onTimeout: { stream.abort() }) {
            guard case .join(let guest) = try await channel.receive(), guest.id == preamble.caller,
                  guest.share.count == LinkKeys.shareLength else { throw StreamError.closed }
            channel.send(.welcome(mine))
            return guest
        }
        channel.close()
        guard let guest else {
            inviteSpent = false
            return
        }
        let key = LinkKeys.linkKey(secret: invite.secret, inviter: me, inviterShare: mine.share, guest: guest.id, guestShare: guest.share)
        let named = LinkName.clean(guest.name)
        let phone = LinkedPhone(id: guest.id, name: named.isEmpty ? "iPhone" : named, key: key, linkedAt: .now)
        add(phone)
        if self.invite == invite { inviteOutcome = .linked(phone.name) }
    }

    /// A newly linked phone; linking a phone again replaces its old key.
    private func add(_ phone: LinkedPhone) {
        disconnect(phone.id)
        failures[phone.id] = nil
        phones.removeAll { $0.id == phone.id }
        phones.append(phone)
        save()
        refresh()
        callIfNeeded(phone.id)
    }

    /// Drops a phone that was unlinked, here or by the other phone.
    private func forget(_ peer: LinkID) {
        disconnect(peer)
        failures[peer] = nil
        phones.removeAll { $0.id == peer }
        save()
        if controlling == peer { stopControlling() }
        refresh()
    }

    // MARK: Controlling

    /// Shows this phone's remote for a linked phone.
    func control(_ peer: LinkID) {
        guard controlling != peer, let session, let themeStore, linkedPhone(peer) != nil else { return }
        stopControlling()
        let remote = LinkRemote(link: self, peer: peer, tiltEnabled: session.glasses.tiltEnabled)
        self.remote = remote
        controlling = peer
        window.show(remote: remote, session: session, store: themeStore)
    }

    func stopControlling() {
        controlling = nil
        remote = nil
        window.hide()
    }

    /// Puts the remote away and opens this iPhone's Settings.
    func openSettings() {
        stopControlling()
        session?.showsSettings = true
    }

    /// Input or a command from this phone's remote, for the phone it controls.
    func send(_ message: LinkMessage) {
        guard let controlling else { return }
        links[controlling]?.wire.send(message)
    }

    // MARK: Running

    /// Starts or stops the networking to match: on, in front, and with a phone to find or a code on show.
    private func refresh() {
        let wanted = isEnabled && foreground
        if wanted && id == nil { load() }
        if wanted && id != nil && (!phones.isEmpty || invite != nil) { start() } else { stop() }
    }

    private func load() {
        guard let vault = store.load() else { return }
        id = vault.id
        phones = vault.phones
    }

    private func save() {
        guard let id else { return }
        store.save(LinkStore.Vault(id: id, phones: phones))
    }

    private func start() {
        guard let id else { return }
        running = true
        if ticker == nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    tick()
                    try? await Task.sleep(for: Self.tickInterval)
                }
            }
        }
        #if DEBUG
        if let fake {
            if links[fake.id] == nil { connected(fake, to: fake.id, caller: fake.id) }
            return
        }
        #endif
        if listener == nil { listen(as: id) }
        if browser == nil { browse() }
    }

    private func stop() {
        guard running else { return }
        running = false
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        restart?.cancel()
        restart = nil
        ticker?.cancel()
        ticker = nil
        for call in calls.values { call.cancel() }
        calls = [:]
        failures = [:]
        nearby = []
        for peer in Array(links.keys) { disconnect(peer) }
    }

    /// Makes a failed listener or browser again a little later; a network change can fail them.
    private func restartLater() {
        restart?.cancel()
        restart = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            restart = nil
            refresh()
        }
    }

    /// Answers calls under this phone's link id, the Bonjour instance linked phones look for.
    private func listen(as id: LinkID) {
        guard let listener = try? NWListener(using: LinkTransport.parameters()) else { return restartLater() }
        listener.service = NWListener.Service(name: id.description, type: LinkTransport.serviceType)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.answer(TCPStream.accept(connection)) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard case .failed = state else { return }
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else { return }
                listener.cancel()
                self.listener = nil
                self.restartLater()
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func browse() {
        let browser = NWBrowser(for: .bonjour(type: LinkTransport.serviceType, domain: "local."), using: LinkTransport.browseParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> String? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return name
            }
            MainActor.assumeIsolated { self?.found(names) }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            let denied: Bool
            let failed: Bool
            switch state {
            case .ready: (denied, failed) = (false, false)
            case .waiting(let error): (denied, failed) = (Self.isDenial(error), false)
            case .failed(let error): (denied, failed) = (Self.isDenial(error), true)
            default: return
            }
            MainActor.assumeIsolated {
                guard let self, let browser, self.browser === browser else { return }
                self.isDenied = denied
                guard failed else { return }
                browser.cancel()
                self.browser = nil
                self.restartLater()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// Local Network access turned off for Marquee answers Bonjour with kDNSServiceErr_PolicyDenied.
    nonisolated private static func isDenial(_ error: NWError) -> Bool {
        guard case .dns(let code) = error else { return false }
        return code == -65570
    }

    private func found(_ names: [String]) {
        nearby = Set(names.compactMap { LinkID($0) })
        for phone in phones { callIfNeeded(phone.id) }
    }

    private func callIfNeeded(_ peer: LinkID) {
        guard running, let me = id, nearby.contains(peer), links[peer] == nil, calls[peer] == nil else { return }
        let wait = failures[peer].map { LinkDialing.retryDelay(failures: $0) } ?? LinkDialing.delay(me: me, peer: peer)
        calls[peer] = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.call(peer, as: me)
        }
    }

    /// Opens a session with a linked phone Bonjour found. A task cancelled on the way leaves `calls` to
    /// whoever cancelled it.
    private func call(_ peer: LinkID, as me: LinkID) async {
        guard let phone = linkedPhone(peer), running, links[peer] == nil else {
            calls[peer] = nil
            return
        }
        let stream = LinkTransport.dial(peer)
        let preamble = LinkPreamble(mode: .session, caller: me)
        let psk = LinkKeys.sessionKey(linkKey: phone.key)
        let channel = try? await withTaskCancellationHandler {
            try await withDeadline(Self.deadline, onTimeout: { stream.abort() }) {
                try await LinkTransport.call(stream, preamble: preamble, psk: psk)
            }
        } onCancel: {
            stream.abort()
        }
        guard !Task.isCancelled else {
            channel?.close()
            return
        }
        calls[peer] = nil
        guard let channel else {
            failures[peer, default: 0] += 1
            callIfNeeded(peer)
            return
        }
        failures[peer] = nil
        connected(channel, to: peer, caller: me)
    }

    /// A call from another phone: a linked one opening a session, or one pairing with the code on show.
    private func answer(_ stream: TCPStream) {
        guard running else { return stream.abort() }
        Task { [weak self] in
            let preamble = try? await withDeadline(Self.deadline, onTimeout: { stream.abort() }) {
                try await LinkTransport.preamble(stream)
            }
            guard let preamble, let self else { return stream.abort() }
            switch preamble.mode {
            case .session: await answerSession(stream, preamble: preamble)
            case .pairing: await answerPairing(stream, preamble: preamble)
            }
        }
    }

    /// A phone this one does not know (never linked, or unlinked here) gets no answer.
    private func answerSession(_ stream: TCPStream, preamble: LinkPreamble) async {
        guard running, let phone = linkedPhone(preamble.caller) else { return stream.abort() }
        let psk = LinkKeys.sessionKey(linkKey: phone.key)
        let channel = try? await withDeadline(Self.deadline, onTimeout: { stream.abort() }) {
            try await LinkTransport.answer(stream, preamble: preamble, psk: psk)
        }
        guard let channel else { return stream.abort() }
        connected(channel, to: phone.id, caller: phone.id)
    }

    private func connected(_ wire: any LinkWire, to peer: LinkID, caller: LinkID) {
        guard running, linkedPhone(peer) != nil else { return wire.close() }
        if let existing = links[peer] {
            guard LinkDialing.keepsNew(existingCaller: existing.caller, newCaller: caller) else { return wire.close() }
            disconnect(peer)
        }
        calls.removeValue(forKey: peer)?.cancel()
        tokens += 1
        let token = tokens
        links[peer] = Connection(wire: wire, caller: caller, token: token, heardAt: Self.now)
        presence[peer] = Presence()
        wire.send(.hello(name: name))
        publish()
        if let channel = wire as? LinkChannel {
            links[peer]?.reader = Task { [weak self] in
                while let message = try? await channel.receive() {
                    self?.received(message, from: peer, token: token)
                }
                self?.ended(peer, token: token)
            }
        }
    }

    private func disconnect(_ peer: LinkID) {
        guard let connection = links.removeValue(forKey: peer) else { return }
        connection.reader?.cancel()
        connection.wire.close()
        presence[peer] = nil
    }

    private func ended(_ peer: LinkID, token: Int) {
        guard links[peer]?.token == token else { return }
        disconnect(peer)
        callIfNeeded(peer)
    }

    private func received(_ message: LinkMessage, from peer: LinkID, token: Int) {
        guard links[peer]?.token == token else { return }
        links[peer]?.heardAt = Self.now
        switch message {
        case .hello(let name):
            rename(peer, to: name)
        case .status(let status):
            presence[peer] = Presence(status: status, statusAt: .now)
        case .input(let input):
            guard let session else { return }
            if let cue = LinkHost.handle(input, in: session) { links[peer]?.wire.send(.cue(cue)) }
            publish()
        case .command(let command):
            guard let session else { return }
            LinkHost.handle(command, in: session)
            publish()
        case .cue(let cue):
            if controlling == peer { remote?.onCue?(cue) }
        case .unlink:
            forget(peer)
        case .join, .welcome:
            break
        }
    }

    private func rename(_ peer: LinkID, to name: String) {
        let name = LinkName.clean(name)
        guard !name.isEmpty, let index = phones.firstIndex(where: { $0.id == peer }), phones[index].name != name else { return }
        phones[index].name = name
        save()
    }

    private func tick() {
        let now = Self.now
        for (peer, connection) in links where now - connection.heardAt > Self.silence {
            ended(peer, token: connection.token)
        }
        publish()
    }

    /// Sends this phone's status to each connected phone that needs it (`LinkStatusPacer`).
    private func publish() {
        guard let session, !links.isEmpty else { return }
        let status = LinkHost.status(of: session).limited()
        let now = Self.now
        for peer in Array(links.keys) {
            guard links[peer]?.pacer.shouldSend(status, now: now) == true else { continue }
            links[peer]?.wire.send(.status(status))
        }
    }

    #if DEBUG
    /// UI tests: `-marquee.uitest.link YES` turns linked phones on; `-marquee.uitest.linkScan YES` makes
    /// Scan Link Code read a stand-in phone's code; `-marquee.uitest.linkPeer tv|glasses|phone|idle` links
    /// a stand-in phone, connected, that drives a TV, glasses, its own player, or nothing.
    func simulate(arguments: UserDefaults) {
        let mode = arguments.string(forKey: "marquee.uitest.linkPeer").flatMap(FakeLinkPhone.Mode.init(rawValue:))
        guard arguments.bool(forKey: "marquee.uitest.link") || mode != nil else { return }
        setEnabled(true)
        if arguments.bool(forKey: "marquee.uitest.linkScan") {
            simulatedScan = LinkInvite(id: FakeLinkPhone.id, name: FakeLinkPhone.name)
        }
        guard let mode else { return }
        load()
        fake = FakeLinkPhone(mode: mode) { [weak self] message in
            guard let self, let token = links[FakeLinkPhone.id]?.token else { return }
            received(message, from: FakeLinkPhone.id, token: token)
        }
        phones = [LinkedPhone(id: FakeLinkPhone.id, name: FakeLinkPhone.name, key: LinkKeys.randomBytes(LinkKeys.keyLength), linkedAt: .now)]
        save()
        refresh()
    }
    #endif
}
