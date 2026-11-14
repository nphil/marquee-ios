import MarqueeCore
import SwiftUI

struct DownloadSettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var downloads = session.downloads
        List {
            Section {
                NavigationLink("Downloads") { DownloadsView() }
                    .accessibilityIdentifier("downloads.open")
                LabeledContent("Storage Used", value: ByteCountFormatter.string(fromByteCount: downloads.store.bytesOnDisk(), countStyle: .file))
                Picker("Default Quality", selection: $downloads.settings.quality) {
                    ForEach(DownloadQuality.choices, id: \.self) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .accessibilityIdentifier("downloads.quality")
            } footer: {
                Text("Original keeps the server's file. High, Medium and Low ask the server to convert it while it downloads, each at the size the title needs for that quality.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)

            Section {
                Toggle("Allow Cellular Downloads", isOn: $downloads.settings.cellular)
                    .accessibilityIdentifier("downloads.cellular")
                Toggle("Continue in Background", isOn: $downloads.settings.keepAlive)
                    .accessibilityIdentifier("downloads.keepAlive")
                Toggle("Auto-delete Watched", isOn: $downloads.settings.autoDeleteWatched)
                    .accessibilityIdentifier("downloads.autoDeleteWatched")
            } footer: {
                Text("Background transfers depend on iOS and may stop when the app is closed. Watched downloads are removed after playback.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme)
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
    }
}
