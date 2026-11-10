import MarqueeCore
import SwiftUI

/// Seerr's cookie from a sign-in with Plex, for the profile and the address it belongs to.
struct SeerrSession: Codable, Equatable {
    var owner: String
    var address: URL
    var cookie: String
}

/// Seerr's address and sign-in, the last connection test, Pulsarr, and the client the Requests screen
/// uses.
@MainActor @Observable
final class SeerrSettings {
    enum Check: Equatable {
        case untested
        case testing
        case connected(version: String, user: SeerrUser)
        case failed(SeerrError)
    }

    private(set) var config: SeerrConfig?
    private(set) var check = Check.untested
    /// Pulsarr also requests what goes on a Plex Watchlist, which Seerr can't tell, so this says so.
    var pulsarr: Bool {
        didSet { storage.seerrPulsarr = pulsarr }
    }
    /// Bumped by each request sent, so Requests shows it on return.
    private(set) var requestsSent = 0
    @ObservationIgnored private let storage: SessionStorage
    @ObservationIgnored private let transport: any PlexTransport
    @ObservationIgnored private var testTask: Task<Void, Never>?
    @ObservationIgnored private var cached: (key: ClientKey, client: SeerrClient)?

    private struct ClientKey: Equatable {
        let config: SeerrConfig
        let owner: String
        let token: String?
    }

    init(storage: SessionStorage) {
        self.storage = storage
        let configuration = URLSessionConfiguration.ephemeral
        // The client keeps Seerr's cookies itself; the URL session must neither store nor add any.
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        FakePlex.install(into: configuration)
        transport = URLSessionTransport(session: URLSession(configuration: configuration))
        config = storage.seerr
        pulsarr = storage.seerrPulsarr
    }

    /// An address is saved; Requests is offered.
    var isEnabled: Bool { config != nil }

    /// The client for the active profile, kept while the address, sign-in and profile stay the same so
    /// its Seerr session carries on.
    var client: SeerrClient? {
        guard let config else { return nil }
        let owner = storage.profile?.uuid ?? ""
        let token: String? = if case .plex = config.auth { storage.accountToken } else { nil }
        let key = ClientKey(config: config, owner: owner, token: token)
        if let cached, cached.key == key { return cached.client }
        let saved = storage.seerrSession.flatMap { $0.owner == owner && $0.address == config.address ? $0.cookie : nil }
        let address = config.address
        let client = SeerrClient(config: config, transport: transport, plexToken: token, session: saved) { [weak self] cookie in
            Task { @MainActor in self?.remember(cookie, owner: owner, address: address) }
        }
        cached = (key, client)
        return client
    }

    func save(_ config: SeerrConfig?) {
        guard config != self.config else { return }
        testTask?.cancel()
        self.config = config
        storage.seerr = config
        storage.seerrSession = nil
        cached = nil
        check = .untested
        if config == nil { pulsarr = false }
    }

    func test() {
        guard let client else { return }
        testTask?.cancel()
        check = .testing
        testTask = Task {
            let result: Check
            do {
                let version = try await client.version()
                result = .connected(version: version, user: try await client.signIn())
            } catch {
                result = .failed(error as? SeerrError ?? .unreachable)
            }
            guard !Task.isCancelled else { return }
            check = result
        }
    }

    /// Sends a request and, once Seerr takes it, has Requests reload.
    func request(_ order: SeerrOrder) async throws {
        guard let client else { throw SeerrError.unreachable }
        try await client.request(order)
        requestsSent += 1
    }

    private func remember(_ cookie: String, owner: String, address: URL) {
        guard config?.address == address else { return }
        storage.seerrSession = SeerrSession(owner: owner, address: address, cookie: cookie)
    }
}

/// The Seerr integration (DESIGN §8.7): an address, a sign-in with the Plex profile or an API key, a
/// connection test, Pulsarr, and Forget. A saved address is what turns it on.
struct SeerrView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @State private var address = ""
    @State private var method = Method.plex
    @State private var key = ""
    @State private var confirmsForget = false
    @FocusState private var focus: Field?

    private enum Field { case address, key }

    private enum Method: Hashable {
        case plex, apiKey
    }

    var body: some View {
        @Bindable var seerr = session.seerr
        List {
            Section {
                LabeledContent("Address") {
                    TextField("Address", text: $address, prompt: Text(verbatim: "https://seerr.local").foregroundStyle(theme.ink3))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .submitLabel(method == .apiKey ? .next : .done)
                        .focused($focus, equals: .address)
                        .onSubmit {
                            if method == .apiKey { focus = .key } else { test() }
                        }
                        .accessibilityIdentifier("seerr.address")
                }
            } footer: {
                if let problem = shownProblem, problem != .key {
                    ProblemLine(text: Self.text(for: problem))
                } else {
                    Text("Seerr takes requests for movies and series and hands them to Radarr and Sonarr. With its address, Requests can find titles and ask for them.")
                        .foregroundStyle(theme.ink2)
                }
            }
            .listRowBackground(theme.sheet)

            Section {
                Picker("Sign In With", selection: $method) {
                    Text("Plex Profile").tag(Method.plex)
                    Text("API Key").tag(Method.apiKey)
                }
                .accessibilityIdentifier("seerr.method")
                if method == .apiKey {
                    LabeledContent("API Key") {
                        SecureField("API Key", text: $key, prompt: Text("Required").foregroundStyle(theme.ink3))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .submitLabel(.done)
                            .focused($focus, equals: .key)
                            .onSubmit(test)
                            .accessibilityIdentifier("seerr.key")
                    }
                }
            } footer: {
                if shownProblem == .key {
                    ProblemLine(text: Self.text(for: .key))
                } else if method == .plex {
                    Text("Signs in as the Plex profile in use, like Seerr's own Sign In with Plex, so requests are that profile's.")
                        .foregroundStyle(theme.ink2)
                } else {
                    Text("Requests are made as the key's owner, usually Seerr's admin. The key is in Seerr under Settings, General.")
                        .foregroundStyle(theme.ink2)
                }
            }
            .listRowBackground(theme.sheet)

            Section {
                Button(action: test) {
                    HStack {
                        Text("Test Connection")
                        Spacer()
                        if seerr.check == .testing {
                            ProgressView()
                        }
                    }
                }
                .disabled(draft == nil || seerr.check == .testing)
                .accessibilityIdentifier("seerr.test")
            } footer: {
                status(seerr)
                    .accessibilityIdentifier("seerr.status")
            }
            .listRowBackground(theme.sheet)

            if seerr.config != nil {
                Section {
                    Toggle("Pulsarr", isOn: $seerr.pulsarr)
                        .accessibilityIdentifier("seerr.pulsarr")
                } footer: {
                    Text("Turn on when Pulsarr requests whatever goes on a Plex Watchlist. Title pages then say when adding a title to the Watchlist requests it too.")
                        .foregroundStyle(theme.ink2)
                }
                .listRowBackground(theme.sheet)

                Section {
                    Button("Forget Seerr", role: .destructive) { confirmsForget = true }
                        .accessibilityIdentifier("seerr.forget")
                        .confirmationDialog("Forget Seerr?", isPresented: $confirmsForget, titleVisibility: .visible) {
                            Button("Forget", role: .destructive) {
                                seerr.save(nil)
                                address = ""
                                key = ""
                                method = .plex
                            }
                        } message: {
                            Text("The address, sign-in and API key are removed from this iPhone, and Requests goes away.")
                        }
                }
                .listRowBackground(theme.sheet)
            }
        }
        .themedList(theme)
        .navigationTitle("Seerr")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            address = seerr.config?.address.absoluteString ?? ""
            if case .apiKey(let saved) = seerr.config?.auth {
                method = .apiKey
                key = saved
            }
        }
        .onChange(of: draft) { _, config in
            if let config { seerr.save(config) }
        }
    }

    private var parsed: Result<SeerrConfig, SeerrConfig.Problem> {
        SeerrConfig.parse(address: address, apiKey: method == .apiKey ? key : nil)
    }

    private var draft: SeerrConfig? {
        try? parsed.get()
    }

    /// A problem shows once its field is left, not while it is being typed.
    private var shownProblem: SeerrConfig.Problem? {
        guard case .failure(let problem) = parsed else { return nil }
        if problem == .key {
            return key.isEmpty || focus == .key ? nil : problem
        }
        return address.isEmpty || focus == .address ? nil : problem
    }

    private func test() {
        guard let draft else { return }
        focus = nil
        session.seerr.save(draft)
        session.seerr.test()
    }

    @ViewBuilder
    private func status(_ seerr: SeerrSettings) -> some View {
        switch seerr.check {
        case _ where seerr.config == nil:
            Text("Not set up. Add Seerr's address, then test the connection. An API key stays on this iPhone, in the Keychain like the Plex sign-in.")
                .foregroundStyle(theme.ink2)
        case .untested:
            Text("Not tested yet.")
                .foregroundStyle(theme.ink2)
        case .testing:
            Text("Checking… Signing in to Seerr.")
                .foregroundStyle(theme.ink2)
        case .connected(let version, let user):
            StatusLine(symbol: "checkmark.circle.fill", tint: theme.positive, text: "Connected · Seerr \(version), signed in as \(user.name).")
        case .failed(let error):
            ProblemLine(text: Self.text(for: error))
        }
    }

    static func text(for problem: SeerrConfig.Problem) -> String {
        switch problem {
        case .scheme: "The address must start with https:// or http://."
        case .host: "That is not a valid address."
        case .plaintext: "Plain http:// is only for addresses on your home network. Use https:// for any other."
        case .key: "That is not a valid API key."
        }
    }

    /// Also what Requests and title pages say when Seerr can't load or refuses a request.
    static func text(for error: SeerrError) -> String {
        switch error {
        case .unreachable: "Can't reach Seerr. No answer from that address. Check it, and that this iPhone is on the same network."
        case .timedOut: "Seerr took too long to answer. Try again in a moment."
        case .badKey: "Seerr refused the key. The address answers, but the API key is wrong. Copy it again from Seerr."
        case .notSeerr: "That is not Seerr. The address answers, but not like Seerr. Check the address."
        case .notSignedIn: "Sign in to Plex first. Seerr signs in with the Plex profile in use."
        case .plexAccountNotAllowed: "Seerr doesn't let this Plex profile in. Seerr's admin can import it under Users, or sign in with an API key instead."
        case .plexSignInFailed: "Seerr couldn't check this profile with Plex. Plex sign-in may be off in Seerr; an API key works instead."
        case .notAllowed: "This account may not make requests in Seerr."
        case .quotaReached: "This account has used up its requests for now. Seerr's admin sets the limit."
        case .alreadyRequested: "Already requested. Everything asked for is requested or available."
        case .notFound: "Seerr no longer has this title."
        case .failed(let message?): "Seerr answered with an error: \(message)"
        case .failed: "Seerr answered with an error."
        }
    }
}
