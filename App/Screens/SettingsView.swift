import SwiftUI

/// Settings (DESIGN §8.7). Home rows and playback, audio and subtitle choices belong to the active Plex
/// profile; the theme and the integrations belong to the iPhone.
struct SettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @Environment(ThemeStore.self) private var store
    @State private var confirmingSignOut = false
    @State private var confirmingDelete = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        @Bindable var session = session
        List {
            Section("Account") {
                Button {
                    session.showsProfileSwitcher = true
                } label: {
                    HStack(spacing: Space.s3) {
                        AvatarView(user: session.user, size: Size.target - Space.s2)
                        VStack(alignment: .leading, spacing: Space.s1) {
                            Text(session.user?.title ?? "Plex Account")
                                .foregroundStyle(theme.ink)
                            Text("Switch Profile")
                                .textRole(.caption)
                                .foregroundStyle(theme.ink2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("settings.profile")
                NavigationLink {
                    ServerListView()
                } label: {
                    LabeledContent("Server") {
                        Text(session.server?.name ?? "")
                            .foregroundStyle(theme.ink2)
                    }
                }
                .accessibilityIdentifier("settings.server")
            }
            .listRowBackground(theme.sheet)

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

            Section("Home") {
                NavigationLink {
                    HomeRowsView()
                } label: {
                    LabeledContent {
                        Text(session.settings.homeRows.isDefault ? "Default" : "Custom")
                            .foregroundStyle(theme.ink2)
                    } label: {
                        Text("Rows")
                    }
                }
                .accessibilityIdentifier("settings.homeRows")
            }
            .listRowBackground(theme.sheet)

            Section("Library") {
                NavigationLink {
                    FavoriteLibrariesView()
                } label: {
                    LabeledContent {
                        Text(session.settings.hiddenLibraries.isEmpty ? "All" : "Some")
                            .foregroundStyle(theme.ink2)
                    } label: {
                        Text("Favorite Libraries")
                    }
                }
                .accessibilityIdentifier("settings.favoriteLibraries")
                NavigationLink {
                    UnderPostersView()
                } label: {
                    LabeledContent {
                        Text(session.settings.posterLabels.summary)
                            .foregroundStyle(theme.ink2)
                    } label: {
                        Text("Under Posters")
                    }
                }
                .accessibilityIdentifier("settings.underPosters")
            }
            .listRowBackground(theme.sheet)

            Section {
                NavigationLink("Video & Playback") {
                    VideoPlaybackSettingsView()
                }
                .accessibilityIdentifier("settings.video")
                NavigationLink("Audio & Subtitles") {
                    AudioSubtitleSettingsView()
                }
                .accessibilityIdentifier("settings.audio")
            } header: {
                Text("Playback")
            } footer: {
                Text("Saved for \(session.user?.title ?? "this profile").")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)

            Section("Integrations") {
                NavigationLink {
                    SpeechDockView()
                } label: {
                    LabeledContent("SpeechDock") {
                        Text(session.speechDock.origin == nil ? "Off" : "On")
                            .foregroundStyle(theme.ink2)
                    }
                }
                .accessibilityIdentifier("settings.speechDock")
                NavigationLink {
                    BazarrView()
                } label: {
                    LabeledContent("Bazarr") {
                        Text(session.bazarr.config == nil ? "Off" : "On")
                            .foregroundStyle(theme.ink2)
                    }
                }
                .accessibilityIdentifier("settings.bazarr")
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
                .accessibilityIdentifier("settings.notices")
            }
            .listRowBackground(theme.sheet)

            Section {
                // Signing out is not something going wrong, so the row keeps the accent; the
                // confirmation carries the destructive style (DESIGN §5.2, §11).
                Button("Sign Out") {
                    confirmingSignOut = true
                }
                .foregroundStyle(theme.accentText)
                .accessibilityIdentifier("settings.signOut")
                // On the button, so the dialog points at the row that opened it.
                .signOutConfirmation(isPresented: $confirmingSignOut, session: session)
            }
            .listRowBackground(theme.sheet)

            Section {
                Button("Delete All Local Data", role: .destructive) {
                    confirmingDelete = true
                }
                .accessibilityIdentifier("settings.deleteData")
                .confirmationDialog("Delete all local data?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("Delete All Local Data", role: .destructive) {
                        let store = store
                        Task {
                            await session.deleteAllLocalData()
                            store.reset()
                        }
                    }
                    .accessibilityIdentifier("settings.deleteData.confirm")
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This signs out and removes everything Marquee keeps on this iPhone: the sign-in, every profile's settings, remembered tracks, themes, Live TV lists and cached artwork. Nothing on the Plex server changes.")
                }
            } footer: {
                Text("Signs out and returns Marquee to how it was when first installed.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme)
        .navigationTitle("Settings")
        .toolbarTitleDisplayMode(.inlineLarge)
        .sheet(isPresented: $session.showsProfileSwitcher) {
            ProfileSwitcher()
                .preferredColorScheme(store.presentationScheme(for: theme))
        }
    }
}

extension View {
    /// A system inset-grouped list on the theme's canvas, rows 56 pt minimum, under the chosen header style.
    /// A partial sheet passes `onCanvas: false` to keep the system glass behind it (DESIGN §6) and the soft
    /// edge with it.
    func themedList(_ theme: Theme, onCanvas: Bool = true) -> some View {
        listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(onCanvas ? theme.canvas : .clear)
            .foregroundStyle(theme.ink, theme.ink2)
            .environment(\.defaultMinListRowHeight, Size.rowMin)
            .scrollHeader(band: onCanvas)
    }
}
