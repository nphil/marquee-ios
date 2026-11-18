import MarqueeCore
import SwiftUI

/// Diagnostic Logs (DESIGN §8.12): the ntfy server, topic and access token the log goes to, this iPhone's
/// name on its messages, live sending, how much is kept, the floating report button, a connection test and a
/// report on demand. A saved server and topic are what turn it on.
struct DiagnosticsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @State private var server = ""
    @State private var topic = ""
    @State private var token = ""
    @State private var name = ""
    @State private var confirmsForget = false
    @FocusState private var focus: Field?

    private enum Field { case server, topic, token, name }

    var body: some View {
        let diagnostics = session.diagnostics
        List {
            Section {
                LabeledContent("Server") {
                    TextField("Server", text: $server, prompt: Text(verbatim: "https://ntfy.nateshome.net").foregroundStyle(theme.ink3))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.next)
                        .focused($focus, equals: .server)
                        .onSubmit { focus = .topic }
                        .accessibilityIdentifier("diagnostics.server")
                }
                LabeledContent("Topic") {
                    TextField("Topic", text: $topic, prompt: Text("Required").foregroundStyle(theme.ink3))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.next)
                        .focused($focus, equals: .topic)
                        .onSubmit { focus = .token }
                        .accessibilityIdentifier("diagnostics.topic")
                }
                LabeledContent("Access Token") {
                    SecureField("Access Token", text: $token, prompt: Text("Optional").foregroundStyle(theme.ink3))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.done)
                        .focused($focus, equals: .token)
                        .onSubmit(test)
                        .accessibilityIdentifier("diagnostics.token")
                }
            } footer: {
                if let problem = shownProblem {
                    ProblemLine(text: Self.text(for: problem))
                } else {
                    Text("Marquee keeps a log of what it does on this iPhone. With an ntfy server and topic, it sends the log there, where it can be read to find out what went wrong. Anyone who can read the topic can read the log, so use a server that asks for an access token. The token stays on this iPhone, in the Keychain.")
                        .foregroundStyle(theme.ink2)
                }
            }
            .listRowBackground(theme.sheet)

            Section {
                LabeledContent("Name") {
                    TextField("Name", text: $name, prompt: Text(diagnostics.defaultName).foregroundStyle(theme.ink3))
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.done)
                        .focused($focus, equals: .name)
                        .onSubmit { diagnostics.setName(name) }
                        .accessibilityIdentifier("diagnostics.name")
                }
                Toggle("Send Live Logs", isOn: Binding(get: { diagnostics.sendsLive }, set: { diagnostics.setLive($0) }))
                    .accessibilityIdentifier("diagnostics.live")
                Picker("Detail", selection: Binding(get: { diagnostics.detailed }, set: { diagnostics.setDetailed($0) })) {
                    Text("Standard").tag(false)
                    Text("Detailed").tag(true)
                }
                .accessibilityIdentifier("diagnostics.detail")
                Toggle("Floating Report Button", isOn: Binding(get: { diagnostics.showsButton }, set: { diagnostics.setButton($0) }))
                    .accessibilityIdentifier("diagnostics.button")
            } footer: {
                Text("Messages from this iPhone are titled “\(diagnostics.title)”. Live logs go out every ten seconds while Marquee is open, and within a second of a problem. Detailed adds every tap, every request and the playhead every ten seconds, for while a problem is being chased. The floating button stays above everything, video included, and sends a report with a screenshot.")
                    .foregroundStyle(theme.ink2)
            }
            .disabled(diagnostics.config == nil)
            .listRowBackground(theme.sheet)

            Section {
                Button(action: test) {
                    HStack {
                        Text("Test Connection")
                        Spacer()
                        if diagnostics.check == .testing {
                            ProgressView()
                        }
                    }
                }
                .disabled(draft == nil || diagnostics.check == .testing)
                .accessibilityIdentifier("diagnostics.test")
                Button("Send Report Now") {
                    focus = nil
                    ReportCenter.shared.open(from: .settings, screenshot: nil)
                }
                .disabled(diagnostics.config == nil)
                .accessibilityIdentifier("diagnostics.report")
            } footer: {
                VStack(alignment: .leading, spacing: Space.s2) {
                    status(diagnostics)
                    liveStatus(diagnostics)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("diagnostics.status")
            }
            .listRowBackground(theme.sheet)

            if diagnostics.config != nil {
                Section {
                    Button("Forget This Server", role: .destructive) { confirmsForget = true }
                        .accessibilityIdentifier("diagnostics.forget")
                        .confirmationDialog("Forget Diagnostic Logs?", isPresented: $confirmsForget, titleVisibility: .visible) {
                            Button("Forget", role: .destructive) {
                                diagnostics.save(nil)
                                server = ""
                                topic = ""
                                token = ""
                            }
                        } message: {
                            Text("The server, topic and token are removed from this iPhone, and the log is no longer sent. It is still kept on this iPhone.")
                        }
                }
                .listRowBackground(theme.sheet)
            }
        }
        .themedList(theme)
        .navigationTitle("Diagnostic Logs")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            server = diagnostics.config?.server.absoluteString ?? ""
            topic = diagnostics.config?.topic ?? ""
            token = diagnostics.config?.token ?? ""
            name = diagnostics.name
        }
        .onChange(of: draft) { _, config in
            if let config { diagnostics.save(config) }
        }
        .onChange(of: focus) { old, _ in
            if old == .name { diagnostics.setName(name) }
        }
        .onDisappear { diagnostics.setName(name) }
    }

    private var parsed: Result<NtfyConfig, NtfyConfig.Problem> {
        NtfyConfig.parse(server: server, topic: topic, token: token)
    }

    private var draft: NtfyConfig? {
        try? parsed.get()
    }

    /// A problem shows once its field is left, not while it is being typed.
    private var shownProblem: NtfyConfig.Problem? {
        guard case .failure(let problem) = parsed else { return nil }
        switch problem {
        case .topic: return topic.isEmpty || focus == .topic ? nil : problem
        case .token: return token.isEmpty || focus == .token ? nil : problem
        case .scheme, .host, .plaintext: return server.isEmpty || focus == .server ? nil : problem
        }
    }

    private func test() {
        guard let draft else { return }
        focus = nil
        session.diagnostics.save(draft)
        session.diagnostics.test()
    }

    @ViewBuilder
    private func status(_ diagnostics: DiagnosticsSettings) -> some View {
        switch diagnostics.check {
        case _ where diagnostics.config == nil:
            Text("Not set up. Until a server and topic are added, the log stays on this iPhone, for about a day.")
                .foregroundStyle(theme.ink2)
        case .untested:
            Text("Not tested yet.")
                .foregroundStyle(theme.ink2)
        case .testing:
            Text("Checking… Sending a test message to the topic.")
                .foregroundStyle(theme.ink2)
        case .sent:
            StatusLine(symbol: "checkmark.circle.fill", tint: theme.positive, text: "Connected · A test message went to the topic.")
        case .needsToken:
            ProblemLine(text: "The server wants an access token, or does not know this one. Check the token.")
        case .refused:
            ProblemLine(text: "The server refused the token for this topic. The token's user needs permission to write to it.")
        case .unreachable:
            ProblemLine(text: "Can't reach the server. Check the address, and that this iPhone is online.")
        case .failed(let status):
            ProblemLine(text: "The server answered with an error (\(status)). Try again in a minute.")
        }
    }

    @ViewBuilder
    private func liveStatus(_ diagnostics: DiagnosticsSettings) -> some View {
        switch diagnostics.live {
        case .refused:
            ProblemLine(text: "Live logs stopped: the server refused the token. They start again once a test gets through.")
        case .retrying:
            Text("Live logs are waiting for the server. They are kept on this iPhone and sent once it answers.")
                .foregroundStyle(theme.ink2)
        case .sending(let lastSent?):
            Text("Live logs last sent \(lastSent.formatted(date: .omitted, time: .shortened)).")
                .foregroundStyle(theme.ink2)
        case .off, .sending(.none):
            EmptyView()
        }
    }

    static func text(for problem: NtfyConfig.Problem) -> String {
        switch problem {
        case .scheme: "The server must start with https:// or http://."
        case .host: "That is not a valid server address."
        case .plaintext: "Plain http:// is only for servers on your home network. Use https:// for any other."
        case .topic: "A topic is 1 to 64 letters, digits, - and _."
        case .token: "That is not a valid token."
        }
    }
}
