import MarqueeCore
import SwiftUI

/// Bazarr's address and API key, and the last connection test since either changed.
@MainActor @Observable
final class BazarrSettings {
    enum Check: Equatable {
        case untested
        case testing
        case connected(BazarrStatus)
        case failed(BazarrError)
    }

    private(set) var config: BazarrConfig?
    private(set) var check = Check.untested
    @ObservationIgnored private let storage: SessionStorage
    @ObservationIgnored private let transport: any PlexTransport
    @ObservationIgnored private var testTask: Task<Void, Never>?

    init(storage: SessionStorage, transport: any PlexTransport) {
        self.storage = storage
        self.transport = transport
        config = storage.bazarr
    }

    /// What the player's Find Subtitles asks first, once an address and key are saved.
    var client: BazarrClient? {
        config.map { BazarrClient(config: $0, transport: transport) }
    }

    func save(_ config: BazarrConfig?) {
        guard config != self.config else { return }
        testTask?.cancel()
        self.config = config
        storage.bazarr = config
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
                result = .failed(error as? BazarrError ?? .unreachable)
            }
            guard !Task.isCancelled else { return }
            check = result
        }
    }
}

/// The Bazarr integration (DESIGN §8.7): an address and API key, a connection test, and Forget. A
/// saved address and key are what turn it on; there is no separate switch.
struct BazarrView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @State private var address = ""
    @State private var key = ""
    @State private var confirmsForget = false
    @FocusState private var focus: Field?

    private enum Field { case address, key }

    var body: some View {
        let bazarr = session.bazarr
        List {
            Section {
                LabeledContent("Address") {
                    TextField("Address", text: $address, prompt: Text(verbatim: "https://bazarr.local").foregroundStyle(theme.ink3))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.next)
                        .focused($focus, equals: .address)
                        .onSubmit { focus = .key }
                        .accessibilityIdentifier("bazarr.address")
                }
                LabeledContent("API Key") {
                    SecureField("API Key", text: $key, prompt: Text("Required").foregroundStyle(theme.ink3))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.done)
                        .focused($focus, equals: .key)
                        .onSubmit(test)
                        .accessibilityIdentifier("bazarr.key")
                }
            } footer: {
                if let problem = shownProblem {
                    ProblemLine(text: Self.text(for: problem))
                } else {
                    Text("Bazarr finds subtitles from many providers. With its address and API key, Find Subtitles in the player asks Bazarr first and Plex when Bazarr has nothing. The key is in Bazarr under Settings, General, Security.")
                        .foregroundStyle(theme.ink2)
                }
            }
            .listRowBackground(theme.sheet)

            Section {
                Button(action: test) {
                    HStack {
                        Text("Test Connection")
                        Spacer()
                        if bazarr.check == .testing {
                            ProgressView()
                        }
                    }
                }
                .disabled(draft == nil || bazarr.check == .testing)
                .accessibilityIdentifier("bazarr.test")
            } footer: {
                status(bazarr)
                    .accessibilityIdentifier("bazarr.status")
            }
            .listRowBackground(theme.sheet)

            if bazarr.config != nil {
                Section {
                    Button("Forget This Key", role: .destructive) { confirmsForget = true }
                        .accessibilityIdentifier("bazarr.forget")
                        .confirmationDialog("Forget Bazarr?", isPresented: $confirmsForget, titleVisibility: .visible) {
                            Button("Forget", role: .destructive) {
                                bazarr.save(nil)
                                address = ""
                                key = ""
                            }
                        } message: {
                            Text("The address and API key are removed from this iPhone.")
                        }
                }
                .listRowBackground(theme.sheet)
            }
        }
        .themedList(theme)
        .navigationTitle("Bazarr")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            address = bazarr.config?.address.absoluteString ?? ""
            key = bazarr.config?.apiKey ?? ""
        }
        .onChange(of: draft) { _, config in
            if let config { bazarr.save(config) }
        }
    }

    private var parsed: Result<BazarrConfig, BazarrConfig.Problem> {
        BazarrConfig.parse(address: address, key: key)
    }

    private var draft: BazarrConfig? {
        try? parsed.get()
    }

    /// A problem shows once its field is left, not while it is being typed.
    private var shownProblem: BazarrConfig.Problem? {
        guard case .failure(let problem) = parsed else { return nil }
        if problem == .key {
            return key.isEmpty || focus == .key ? nil : problem
        }
        return address.isEmpty || focus == .address ? nil : problem
    }

    private func test() {
        guard let draft else { return }
        focus = nil
        session.bazarr.save(draft)
        session.bazarr.test()
    }

    @ViewBuilder
    private func status(_ bazarr: BazarrSettings) -> some View {
        switch bazarr.check {
        case _ where bazarr.config == nil:
            Text("Not set up. Add the address and API key, then test the connection. The key stays on this iPhone, in the Keychain like the Plex sign-in.")
                .foregroundStyle(theme.ink2)
        case .untested:
            Text("Not tested yet.")
                .foregroundStyle(theme.ink2)
        case .testing:
            Text("Checking… Asking Bazarr for its version.")
                .foregroundStyle(theme.ink2)
        case .connected(let status):
            StatusLine(symbol: "checkmark.circle.fill", tint: theme.positive, text: Self.text(for: status))
        case .failed(let error):
            ProblemLine(text: Self.text(for: error))
        }
    }

    static func text(for problem: BazarrConfig.Problem) -> String {
        switch problem {
        case .scheme: "The address must start with https:// or http://."
        case .host: "That is not a valid address."
        case .plaintext: "Plain http:// is only for addresses on your home network. Use https:// for any other."
        case .key: "That is not a valid API key."
        }
    }

    static func text(for status: BazarrStatus) -> String {
        let linked = [status.sonarrVersion.map { "Sonarr \($0)" }, status.radarrVersion.map { "Radarr \($0)" }].compactMap { $0 }
        let apps = switch linked.count {
        case 2: " \(linked[0]) and \(linked[1]) are linked."
        case 1: " \(linked[0]) is linked."
        default: ""
        }
        return "Connected · Bazarr \(status.version).\(apps) Find Subtitles in the player now asks Bazarr first."
    }

    static func text(for error: BazarrError) -> String {
        switch error {
        case .badKey: "Bazarr refused the key. The address answers, but the API key is wrong. Copy it again from Bazarr."
        case .notBazarr: "That is not Bazarr. The address answers, but not like Bazarr. Check the address."
        default: "Can't reach Bazarr. No answer from that address. Check it, and that this iPhone is on the same network."
        }
    }
}
