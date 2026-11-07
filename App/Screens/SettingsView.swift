import SwiftUI

/// Settings (DESIGN §8.7). Account, playback, audio and integrations join as they are built.
struct SettingsView: View {
    @Environment(\.theme) private var theme

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        List {
            Section("Appearance") {
                NavigationLink {
                    AppearanceView()
                } label: {
                    LabeledContent {
                        Text(theme.name).foregroundStyle(theme.ink2)
                    } label: {
                        Text("Theme")
                    }
                }
                .accessibilityIdentifier("settings.theme")
            }
            .listRowBackground(theme.sheet)

            Section("About") {
                LabeledContent {
                    Text(version).foregroundStyle(theme.ink2)
                } label: {
                    Text("Version")
                }
                NavigationLink("Open-Source Notices") {
                    NoticesView()
                }
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme)
        .navigationTitle("Settings")
    }
}

extension View {
    /// A system inset-grouped list on the theme's canvas, rows 56 pt minimum.
    func themedList(_ theme: Theme) -> some View {
        listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .foregroundStyle(theme.ink, theme.ink2)
            .environment(\.defaultMinListRowHeight, Size.rowMin)
    }
}
