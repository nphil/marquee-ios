import SwiftUI

/// The Chromecast plugin's page (DESIGN §8.7): on or off, and the receivers on the network while on.
struct CastView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme

    var body: some View {
        let cast = session.cast
        List {
            Section {
                Toggle("Chromecast", isOn: Binding(get: { cast.isEnabled }, set: { cast.setEnabled($0) }))
                    .accessibilityIdentifier("cast.enabled")
            } footer: {
                Text("Adds Chromecasts to the player's AirPlay button. Marquee looks for them on the local network only while the player or this page is open. A Chromecast streams from your Plex server with a token the server forgets within two days.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)

            if cast.isEnabled {
                Section("On This Network") {
                    if cast.devices.isEmpty {
                        Text("Looking for Chromecasts…")
                            .foregroundStyle(theme.ink2)
                    } else {
                        ForEach(cast.devices) { device in
                            LabeledContent(device.name) {
                                Text(device.model ?? "")
                                    .foregroundStyle(theme.ink2)
                            }
                        }
                    }
                }
                .listRowBackground(theme.sheet)
            }
        }
        .themedList(theme)
        .navigationTitle("Chromecast")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { cast.beginSearch() }
        .onDisappear { cast.endSearch() }
    }
}
