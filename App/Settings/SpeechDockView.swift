import SwiftUI

/// The SpeechDock integration (DESIGN §8.7): off until enabled, then an address. Without an address
/// it stays off.
struct SpeechDockView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var session = session
        List {
            Section {
                Toggle("SpeechDock", isOn: $session.speechDockEnabled)
                    .tint(theme.accent)
                    .accessibilityIdentifier("speechDock.enabled")
            } footer: {
                Text("SpeechDock supplies English word timing, so subtitles can appear word by word as they are spoken. It stays off until it has an address.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)

            if session.speechDockEnabled {
                Section {
                    TextField("Address", text: $session.speechDockAddress, prompt: Text("https://speechdock.local").foregroundStyle(theme.ink2))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .accessibilityIdentifier("speechDock.address")
                } header: {
                    Text("Address")
                } footer: {
                    if !session.speechDockAddress.isEmpty, !Self.isValid(session.speechDockAddress) {
                        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(theme.danger)
                                .accessibilityHidden(true)
                            Text("The address starts with http:// or https://.")
                                .foregroundStyle(theme.ink)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("speechDock.invalid")
                    }
                }
                .listRowBackground(theme.sheet)
            }
        }
        .themedList(theme)
        .navigationTitle("SpeechDock")
        .navigationBarTitleDisplayMode(.inline)
    }

    static func isValid(_ address: String) -> Bool {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host() != nil
    }
}
