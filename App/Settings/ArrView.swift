import MarqueeCore
import SwiftUI

/// Radarr's and Sonarr's addresses and API keys, and the last connection test of each since either changed.
@MainActor @Observable
final class ArrSettings {
    enum Check: Equatable {
        case untested
        case testing
        case connected(version: String)
        case failed(ArrError)
    }

    private(set) var configs: [ArrKind: ArrConfig]
    private(set) var checks: [ArrKind: Check] = [:]
    @ObservationIgnored private let storage: SessionStorage
    @ObservationIgnored private let transport: any PlexTransport
    @ObservationIgnored private var testTasks: [ArrKind: Task<Void, Never>] = [:]

    init(storage: SessionStorage, transport: any PlexTransport) {
        self.storage = storage
        self.transport = transport
        var saved: [ArrKind: ArrConfig] = [:]
        for kind in ArrKind.allCases { saved[kind] = storage.arr(kind) }
        configs = saved
    }

    func config(_ kind: ArrKind) -> ArrConfig? {
        configs[kind]
    }

    func check(_ kind: ArrKind) -> Check {
        checks[kind] ?? .untested
    }

    /// Whichever of Radarr and Sonarr has an address and key: what a delete asks to take the title out.
    var services: ArrServices {
        ArrServices(radarr: client(.radarr), sonarr: client(.sonarr))
    }

    private func client(_ kind: ArrKind) -> ArrClient? {
        configs[kind].map { ArrClient(kind: kind, config: $0, transport: transport) }
    }

    func save(_ config: ArrConfig?, for kind: ArrKind) {
        guard config != configs[kind] else { return }
        testTasks[kind]?.cancel()
        configs[kind] = config
        storage.setArr(config, for: kind)
        checks[kind] = nil
    }

    func test(_ kind: ArrKind) {
        guard let client = client(kind) else { return }
        testTasks[kind]?.cancel()
        checks[kind] = .testing
        testTasks[kind] = Task {
            let result: Check
            do {
                result = .connected(version: try await client.version())
            } catch {
                result = .failed(error as? ArrError ?? .unreachable)
                Diag.event(.integration, "\(kind.rawValue).test.failed", ["error": error], .warning)
            }
            guard !Task.isCancelled else { return }
            checks[kind] = result
        }
    }
}

/// The Radarr or Sonarr integration (DESIGN §8.7): an address and API key, a connection test, and Forget.
/// A saved address and key are what turn it on; a delete then also removes the title from this service.
struct ArrView: View {
    let kind: ArrKind
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @State private var address = ""
    @State private var key = ""
    @State private var confirmsForget = false
    @FocusState private var focus: Field?

    private enum Field { case address, key }

    var body: some View {
        let arr = session.arr
        let name = kind.appName
        List {
            Section {
                LabeledContent("Address") {
                    TextField("Address", text: $address, prompt: Text(verbatim: "https://\(kind.rawValue).local").foregroundStyle(theme.ink3))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.next)
                        .focused($focus, equals: .address)
                        .onSubmit { focus = .key }
                        .accessibilityIdentifier("\(kind.rawValue).address")
                }
                LabeledContent("API Key") {
                    SecureField("API Key", text: $key, prompt: Text("Required").foregroundStyle(theme.ink3))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.done)
                        .focused($focus, equals: .key)
                        .onSubmit(test)
                        .accessibilityIdentifier("\(kind.rawValue).key")
                }
            } footer: {
                if let problem = shownProblem {
                    ProblemLine(text: BazarrView.text(for: problem))
                } else {
                    Text("\(purpose) The key is in \(name) under Settings, General, Security.")
                        .foregroundStyle(theme.ink2)
                }
            }
            .listRowBackground(theme.sheet)

            Section {
                Button(action: test) {
                    HStack {
                        Text("Test Connection")
                        Spacer()
                        if arr.check(kind) == .testing {
                            ProgressView()
                        }
                    }
                }
                .disabled(draft == nil || arr.check(kind) == .testing)
                .accessibilityIdentifier("\(kind.rawValue).test")
            } footer: {
                status(arr)
                    .accessibilityIdentifier("\(kind.rawValue).status")
            }
            .listRowBackground(theme.sheet)

            if arr.config(kind) != nil {
                Section {
                    Button("Forget This Key", role: .destructive) { confirmsForget = true }
                        .accessibilityIdentifier("\(kind.rawValue).forget")
                        .confirmationDialog("Forget \(name)?", isPresented: $confirmsForget, titleVisibility: .visible) {
                            Button("Forget", role: .destructive) {
                                arr.save(nil, for: kind)
                                address = ""
                                key = ""
                            }
                        } message: {
                            Text("The address and API key are removed from this iPhone. A delete no longer removes titles from \(name).")
                        }
                }
                .listRowBackground(theme.sheet)
            }
        }
        .themedList(theme)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            address = arr.config(kind)?.address.absoluteString ?? ""
            key = arr.config(kind)?.apiKey ?? ""
        }
        .onChange(of: draft) { _, config in
            if let config { arr.save(config, for: kind) }
        }
    }

    private var purpose: String {
        switch kind {
        case .radarr:
            "Deleting a movie here also removes it from Radarr with its files and adds it to Radarr's import exclusion list, so no list sync adds it back."
        case .sonarr:
            "Deleting a show here, or its last episode, also removes the series from Sonarr with its files and adds it to Sonarr's import exclusion list, so no list sync adds it back."
        }
    }

    private var parsed: Result<ArrConfig, ArrConfig.Problem> {
        ArrConfig.parse(address: address, key: key)
    }

    private var draft: ArrConfig? {
        try? parsed.get()
    }

    /// A problem shows once its field is left, not while it is being typed.
    private var shownProblem: ArrConfig.Problem? {
        guard case .failure(let problem) = parsed else { return nil }
        if problem == .key {
            return key.isEmpty || focus == .key ? nil : problem
        }
        return address.isEmpty || focus == .address ? nil : problem
    }

    private func test() {
        guard let draft else { return }
        focus = nil
        session.arr.save(draft, for: kind)
        session.arr.test(kind)
    }

    @ViewBuilder
    private func status(_ arr: ArrSettings) -> some View {
        switch arr.check(kind) {
        case _ where arr.config(kind) == nil:
            Text("Not set up. Add the address and API key, then test the connection. The key stays on this iPhone, in the Keychain like the Plex sign-in.")
                .foregroundStyle(theme.ink2)
        case .untested:
            Text("Not tested yet.")
                .foregroundStyle(theme.ink2)
        case .testing:
            Text("Checking… Asking \(kind.appName) for its version.")
                .foregroundStyle(theme.ink2)
        case .connected(let version):
            StatusLine(symbol: "checkmark.circle.fill", tint: theme.positive, text: "Connected · \(kind.appName) \(version). Deleting a title here now also removes it from \(kind.appName).")
        case .failed(let error):
            ProblemLine(text: Self.text(for: error, name: kind.appName))
        }
    }

    static func text(for error: ArrError, name: String) -> String {
        switch error {
        case .badKey: "\(name) refused the key. The address answers, but the API key is wrong. Copy it again from \(name)."
        case .notArr: "That is not \(name). The address answers, but not like \(name). Check the address, and that it is not the other of Radarr and Sonarr."
        default: "Can't reach \(name). No answer from that address. Check it, and that this iPhone is on the same network."
        }
    }
}
