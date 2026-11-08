import MarqueeCore
import SwiftUI

/// SpeechDock's address and the last connection test since it changed.
@MainActor @Observable
final class SpeechDockSettings {
    enum Check: Equatable {
        case untested
        case testing
        case connected(version: String)
        case failed(SpeechDock.Failure)
    }

    /// The service's origin. Without one SpeechDock is off: there is no separate switch.
    private(set) var origin: URL?
    private(set) var check = Check.untested
    @ObservationIgnored private let storage: SessionStorage
    @ObservationIgnored private let transport: any PlexTransport
    @ObservationIgnored private var testTask: Task<Void, Never>?

    init(storage: SessionStorage, transport: any PlexTransport) {
        self.storage = storage
        self.transport = transport
        origin = try? SpeechDock.origin(storage.speechDockAddress).get()
    }

    /// What the player asks for word timing, once an address is saved.
    var client: SpeechDockClient? {
        origin.map { SpeechDockClient(origin: $0, transport: transport) }
    }

    func save(_ origin: URL?) {
        guard origin != self.origin else { return }
        testTask?.cancel()
        self.origin = origin
        storage.speechDockAddress = origin?.absoluteString ?? ""
        check = .untested
    }

    func test() {
        guard let client else { return }
        testTask?.cancel()
        check = .testing
        testTask = Task {
            let result: Check
            do {
                result = .connected(version: try await client.health())
            } catch {
                result = .failed(error as? SpeechDock.Failure ?? .unreachable)
            }
            guard !Task.isCancelled else { return }
            check = result
        }
    }
}

/// The SpeechDock integration (DESIGN §8.7): an address and a connection test. A valid address turns it
/// on and an empty one off, as on the TV.
struct SpeechDockView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @State private var address = ""
    @FocusState private var editing: Bool

    var body: some View {
        let speechDock = session.speechDock
        List {
            Section {
                LabeledContent("Address") {
                    TextField("Address", text: $address, prompt: Text(verbatim: "https://speechdock.local").foregroundStyle(theme.ink3))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.done)
                        .focused($editing)
                        .onSubmit(test)
                        .accessibilityIdentifier("speechDock.address")
                }
            } footer: {
                if let problem = shownProblem {
                    ProblemLine(text: Self.text(for: problem))
                        .accessibilityIdentifier("speechDock.invalid")
                } else {
                    Text("SpeechDock receives audio and subtitle text for English alignment. Other languages keep estimated timing. Leave the address empty to disable it.")
                        .foregroundStyle(theme.ink2)
                }
            }
            .listRowBackground(theme.sheet)

            Section {
                Button(action: test) {
                    HStack {
                        Text("Test Connection")
                        Spacer()
                        if speechDock.check == .testing {
                            ProgressView()
                        }
                    }
                }
                .disabled(draft == nil || speechDock.check == .testing)
                .accessibilityIdentifier("speechDock.test")
            } footer: {
                status(speechDock)
                    .accessibilityIdentifier("speechDock.status")
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme)
        .navigationTitle("SpeechDock")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            address = speechDock.origin?.absoluteString ?? ""
        }
        .onChange(of: address) { _, text in
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                speechDock.save(nil)
            } else if case .success(let origin) = SpeechDock.origin(text) {
                speechDock.save(origin)
            }
        }
    }

    private var draft: URL? {
        try? SpeechDock.origin(address).get()
    }

    /// A problem shows once the field is left, not while it is being typed.
    private var shownProblem: SpeechDock.OriginProblem? {
        guard !editing, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              case .failure(let problem) = SpeechDock.origin(address) else { return nil }
        return problem
    }

    private func test() {
        editing = false
        guard let draft else { return }
        session.speechDock.save(draft)
        session.speechDock.test()
    }

    @ViewBuilder
    private func status(_ speechDock: SpeechDockSettings) -> some View {
        switch speechDock.check {
        case _ where speechDock.origin == nil:
            Text("Off. Enter an address, then test the connection.")
                .foregroundStyle(theme.ink2)
        case .untested:
            Text("Not tested yet.")
                .foregroundStyle(theme.ink2)
        case .testing:
            Text("Checking… Asking SpeechDock for its version.")
                .foregroundStyle(theme.ink2)
        case .connected(let version):
            StatusLine(symbol: "checkmark.circle.fill", tint: theme.positive, text: "Connected · SpeechDock \(version).")
        case .failed(let failure):
            ProblemLine(text: Self.text(for: failure))
        }
    }

    static func text(for problem: SpeechDock.OriginProblem) -> String {
        switch problem {
        case .scheme: "The address must start with https:// or http://."
        case .host: "That is not a valid address."
        case .notOrigin: "Enter the address alone, without a sign-in, path, query or fragment."
        case .plaintext: "Plain http:// is only for addresses on your home network. Use https:// for any other."
        }
    }

    static func text(for failure: SpeechDock.Failure) -> String {
        switch failure {
        case .notSpeechDock, .rejected: "That is not SpeechDock. The address answers, but not like SpeechDock. Check the address."
        case .unreachable: "Can't reach SpeechDock. No answer from that address. Check it, and that this iPhone is on the same network."
        }
    }
}
