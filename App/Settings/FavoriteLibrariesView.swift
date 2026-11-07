import MarqueeCore
import SwiftUI

/// Settings › Favorite Libraries: which of the server's libraries this profile sees. The others leave
/// Home and the Library's title menu; Settings keeps listing every one. At least one stays on.
struct FavoriteLibrariesView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.plexLibrary) private var library
    @Environment(\.theme) private var theme
    @State private var sections = Remote<[PlexLibrarySection]>()

    var body: some View {
        RemoteContent(remote: sections) { sections in
            List {
                Section {
                    ForEach(sections) { section in
                        toggle(section, among: sections)
                    }
                } header: {
                    Text("Which libraries this iPhone shows.")
                } footer: {
                    Text("Your favorites fill Home's shelves and the Library's title menu; Settings lists every one you have.")
                        .foregroundStyle(theme.ink2)
                }
                .listRowBackground(theme.sheet)
            }
            .themedList(theme)
        } skeleton: {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.canvas)
        .navigationTitle("Favorite Libraries")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: LoadKey(library: library?.instance, attempt: sections.attempt)) {
            guard let library else { return }
            await sections.load { try await library.sections() }
        }
    }

    private func toggle(_ section: PlexLibrarySection, among sections: [PlexLibrarySection]) -> some View {
        let id = HomeLayout.libraryID(section)
        let hidden = session.settings.hiddenLibraries
        let isOn = !hidden.contains(id)
        let isLast = isOn && sections.allSatisfy { $0.id == section.id || hidden.contains(HomeLayout.libraryID($0)) }
        return Toggle(isOn: Binding {
            isOn
        } set: { on in
            if on { session.settings.hiddenLibraries.remove(id) } else { session.settings.hiddenLibraries.insert(id) }
        }) {
            Text(section.title)
            if isLast {
                Text("At least one library stays on.")
            }
        }
        .disabled(isLast)
        .accessibilityIdentifier("favoriteLibraries.\(section.key)")
    }
}
