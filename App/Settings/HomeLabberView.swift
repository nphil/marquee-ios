import MarqueeCore
import SwiftUI

/// HomeLabber's address and Marquee token, and the last connection test since either changed. A
/// saved address and token hand the quality map to the downloads.
@MainActor @Observable
final class HomeLabberSettings {
    enum Check: Equatable {
        case untested
        case testing
        case connected(QualityMapStatus)
        case failed(HomeLabberError)
    }

    private(set) var config: HomeLabberConfig?
    private(set) var check = Check.untested
    @ObservationIgnored private let storage: SessionStorage
    @ObservationIgnored private let transport: any PlexTransport
    @ObservationIgnored private let downloads: DownloadCenter
    @ObservationIgnored private var testTask: Task<Void, Never>?

    init(storage: SessionStorage, transport: any PlexTransport, downloads: DownloadCenter) {
        self.storage = storage
        self.transport = transport
        self.downloads = downloads
        config = storage.homelabber
        downloads.qualityMap = client
    }

    var client: HomeLabberClient? {
        config.map { HomeLabberClient(config: $0, transport: transport) }
    }

    func save(_ config: HomeLabberConfig?) {
        guard config != self.config else { return }
        testTask?.cancel()
        self.config = config
        storage.homelabber = config
        downloads.qualityMap = client
        check = .untested
    }

    func test() {
        guard let client else { return }
        testTask?.cancel()
        check = .testing
        testTask = Task {
            let result: Check
            do {
                result = .connected(try await client.status())
            } catch {
                result = .failed(error as? HomeLabberError ?? .unreachable)
            }
            guard !Task.isCancelled else { return }
            check = result
        }
    }
}

/// The HomeLabber Quality Map integration (DESIGN §8.7): an address and token, a connection test,
/// and Forget. A saved address and token are what turn it on; there is no separate switch.
struct HomeLabberView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @State private var address = ""
    @State private var token = ""
    @State private var confirmsForget = false
    @FocusState private var focus: Field?

    private enum Field { case address, token }

    var body: some View {
        let homelabber = session.homelabber
        List {
            Section {
                LabeledContent("Address") {
                    TextField("Address", text: $address, prompt: Text(verbatim: "https://homelabber.local").foregroundStyle(theme.ink3))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.next)
                        .focused($focus, equals: .address)
                        .onSubmit { focus = .token }
                        .accessibilityIdentifier("homelabber.address")
                }
                LabeledContent("Token") {
                    SecureField("Token", text: $token, prompt: Text("Required").foregroundStyle(theme.ink3))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.done)
                        .focused($focus, equals: .token)
                        .onSubmit(test)
                        .accessibilityIdentifier("homelabber.token")
                }
            } footer: {
                if let problem = shownProblem {
                    ProblemLine(text: Self.text(for: problem))
                } else {
                    Text("HomeLabber measures overnight how each title looks at different sizes. With its address and a Marquee token, High, Medium and Low downloads use the measured sizes instead of estimates. Make the token in HomeLabber under Settings, Media quality.")
                        .foregroundStyle(theme.ink2)
                }
            }
            .listRowBackground(theme.sheet)

            Section {
                Button(action: test) {
                    HStack {
                        Text("Test Connection")
                        Spacer()
                        if homelabber.check == .testing {
                            ProgressView()
                        }
                    }
                }
                .disabled(draft == nil || homelabber.check == .testing)
                .accessibilityIdentifier("homelabber.test")
            } footer: {
                status(homelabber)
                    .accessibilityIdentifier("homelabber.status")
            }
            .listRowBackground(theme.sheet)

            if homelabber.config != nil {
                Section {
                    Button("Forget This Token", role: .destructive) { confirmsForget = true }
                        .accessibilityIdentifier("homelabber.forget")
                        .confirmationDialog("Forget HomeLabber?", isPresented: $confirmsForget, titleVisibility: .visible) {
                            Button("Forget", role: .destructive) {
                                homelabber.save(nil)
                                address = ""
                                token = ""
                            }
                        } message: {
                            Text("The address and token are removed from this iPhone. Download sizes are estimated again.")
                        }
                }
                .listRowBackground(theme.sheet)
            }
        }
        .themedList(theme)
        .navigationTitle("HomeLabber Quality Map")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            address = homelabber.config?.address.absoluteString ?? ""
            token = homelabber.config?.token ?? ""
        }
        .onChange(of: draft) { _, config in
            if let config { homelabber.save(config) }
        }
    }

    private var parsed: Result<HomeLabberConfig, HomeLabberConfig.Problem> {
        HomeLabberConfig.parse(address: address, token: token)
    }

    private var draft: HomeLabberConfig? {
        try? parsed.get()
    }

    /// A problem shows once its field is left, not while it is being typed.
    private var shownProblem: HomeLabberConfig.Problem? {
        guard case .failure(let problem) = parsed else { return nil }
        if problem == .token {
            return token.isEmpty || focus == .token ? nil : problem
        }
        return address.isEmpty || focus == .address ? nil : problem
    }

    private func test() {
        guard let draft else { return }
        focus = nil
        session.homelabber.save(draft)
        session.homelabber.test()
    }

    @ViewBuilder
    private func status(_ homelabber: HomeLabberSettings) -> some View {
        switch homelabber.check {
        case _ where homelabber.config == nil:
            Text("Not set up. Add the address and token, then test the connection. The token stays on this iPhone, in the Keychain like the Plex sign-in. Until then, download sizes are estimated from each title's details.")
                .foregroundStyle(theme.ink2)
        case .untested:
            Text("Not tested yet.")
                .foregroundStyle(theme.ink2)
        case .testing:
            Text("Checking… Asking HomeLabber how far it has measured.")
                .foregroundStyle(theme.ink2)
        case .connected(let status):
            StatusLine(symbol: "checkmark.circle.fill", tint: theme.positive, text: Self.text(for: status))
        case .failed(let error):
            ProblemLine(text: Self.text(for: error))
        }
    }

    static func text(for problem: HomeLabberConfig.Problem) -> String {
        switch problem {
        case .scheme: "The address must start with https:// or http://."
        case .host: "That is not a valid address."
        case .plaintext: "Plain http:// is only for addresses on your home network. Use https:// for any other."
        case .token: "That is not a valid token."
        }
    }

    static func text(for status: QualityMapStatus) -> String {
        guard status.enabled else { return "Connected · The quality map is off in HomeLabber, so download sizes are estimated." }
        let progress = "\(status.scored.formatted()) of \(status.total.formatted()) titles measured"
        return "Connected · \(progress)\(status.running ? ", measuring now" : ""). The others' download sizes are estimated."
    }

    static func text(for error: HomeLabberError) -> String {
        switch error {
        case .badToken: "HomeLabber refused the token. The address answers, but the token is wrong or was revoked. Make a new one in HomeLabber."
        case .notHomeLabber: "That is not HomeLabber. The address answers, but not like HomeLabber's quality map. Check the address."
        default: "Can't reach HomeLabber. No answer from that address. Check it, and that this iPhone is on the home network or Tailscale."
        }
    }
}
