import MarqueeCore
import SwiftUI

/// Where Home's rows come from and what they are called (DESIGN §8.1).
enum HomeRows {
    /// The Home hubs, then the hubs of the movie and TV libraries in `libraries` (every one when nil),
    /// in the server's order. No library is asked when `libraries` is empty, so a hidden row costs no
    /// request. A library that does not answer leaves its rows out rather than failing Home. Libraries in
    /// `hidden` (switched off under Favorite Libraries) give no rows, and their titles leave the Home hubs.
    static func load(from library: PlexLibrary, libraries: Set<String>?, hidden: Set<String> = []) async throws -> [HomeRow] {
        async let promoted = library.promotedHubs()
        var sections: [PlexLibrarySection] = []
        var hiddenKeys: Set<Int> = []
        if libraries?.isEmpty != true || !hidden.isEmpty {
            let all = try await library.sections()
            hiddenKeys = Set(all.filter { hidden.contains(HomeLayout.libraryID($0)) }.compactMap { Int($0.key) })
            if libraries?.isEmpty != true {
                sections = all.filter { section in
                    (section.type == .movie || section.type == .show)
                        && !hidden.contains(HomeLayout.libraryID(section))
                        && libraries.map { $0.contains(HomeLayout.libraryID(section)) } ?? true
                }
            }
        }
        let hubs = await withTaskGroup(of: (Int, [PlexHub]).self) { group in
            for (index, section) in sections.enumerated() {
                group.addTask { (index, (try? await library.recommendedHubs(in: section.key)) ?? []) }
            }
            var hubs = [[PlexHub]](repeating: [], count: sections.count)
            for await (index, answer) in group { hubs[index] = answer }
            return hubs
        }
        let home = try await promoted.compactMap { hub -> PlexHub? in
            guard !hiddenKeys.isEmpty else { return hub }
            var hub = hub
            hub.items.removeAll { $0.librarySectionID.map(hiddenKeys.contains) ?? false }
            return hub.items.isEmpty ? nil : hub
        }
        return rows(home, library: nil)
            + zip(sections, hubs).flatMap { section, hubs in rows(hubs, library: section) }
    }

    static func isContinueWatching(_ hub: PlexHub) -> Bool {
        hub.style == "hero" || hub.identifier == "home.continue"
    }

    /// Continue Watching and the hubs that hold films or TV, without playlists among their items.
    private static func rows(_ hubs: [PlexHub], library: PlexLibrarySection?) -> [HomeRow] {
        hubs.compactMap { hub in
            let continuing = library == nil && isContinueWatching(hub)
            guard continuing || hub.type.map(videoHubTypes.contains) ?? true else { return nil }
            var hub = hub
            hub.items.removeAll { $0.type == .playlist || $0.type == .unknown }
            return HomeRow(hub: hub, library: library)
        }
    }

    private static let videoHubTypes: Set<String> = ["movie", "show", "season", "episode", "mixed", "clip"]
}

extension HomeRow {
    var isContinueWatching: Bool {
        library == nil && HomeRows.isContinueWatching(hub)
    }

    /// A library's hub carries its library's name, as Plex Web words it: "Top Rated in Movies".
    var title: String {
        if isContinueWatching, hub.title.isEmpty { return "Continue Watching" }
        guard let library else { return hub.title }
        return "\(hub.title) in \(library.title)"
    }
}

/// Home Rows (DESIGN §8.7): every row Home can show, each switched on or off, dragged into Home's
/// order, saved for the profile at once. Home follows each change while this is open.
struct HomeRowsView: View {
    /// Off in a partial sheet, which keeps the system glass (DESIGN §6).
    var onCanvas = true

    @Environment(AppSession.self) private var session
    @Environment(\.plexLibrary) private var library
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var catalogue = Remote<[HomeRow]>()

    var body: some View {
        RemoteContent(remote: catalogue) { rows in
            list(session.settings.homeRows.arrange(rows))
        } skeleton: {
            ScrollView {
                Skeleton.Rows(artSize: HomeRowPreview.size)
                    .padding(.vertical, Space.s6)
            }
            .scrollDisabled(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(onCanvas ? theme.canvas : .clear)
        .navigationTitle("Home Rows")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: LoadKey(library: library?.instance, attempt: catalogue.attempt)) {
            guard let library else { return }
            await catalogue.load { try await HomeRows.load(from: library, libraries: nil) }
        }
    }

    private func list(_ rows: [HomeRow]) -> some View {
        List {
            Section {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    HomeRowToggle(row: row, isOn: Binding(
                        get: { row.shown },
                        set: { shown in
                            var edited = rows
                            edited[index].shown = shown
                            save(edited)
                        }
                    ))
                    .accessibilityActions {
                        if index > 0 {
                            Button("Move Up") { move(rows, from: index, to: index - 1) }
                        }
                        if index < rows.count - 1 {
                            Button("Move Down") { move(rows, from: index, to: index + 2) }
                        }
                    }
                }
                .onMove { source, destination in
                    var edited = rows
                    edited.move(fromOffsets: source, toOffset: destination)
                    // The list has already drawn the drop; animating again would replay it.
                    session.settings.homeRows.save(edited)
                }
            } footer: {
                Text("Drag rows into the order Home shows them. A library's rows appear once switched on.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)

            Section {
                // Borderless, because a list in edit mode does not pass taps to an ordinary row button.
                Button {
                    withAnimation(Motion.spring(reduceMotion: reduceMotion)) {
                        session.settings.homeRows = HomeLayout()
                    }
                } label: {
                    Text("Reset to Default")
                        .frame(maxWidth: .infinity, minHeight: Size.target, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(session.settings.homeRows.isDefault ? theme.ink3 : theme.accentText)
                .disabled(session.settings.homeRows.isDefault)
                .accessibilityIdentifier("homeRows.reset")
            } footer: {
                Text("Saved for \(session.user?.title ?? "this profile"). Reset brings back the server's rows in its order.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme, onCanvas: onCanvas)
        // Always editing, so every row shows its drag handle.
        .environment(\.editMode, .constant(.active))
    }

    private func move(_ rows: [HomeRow], from index: Int, to destination: Int) {
        var edited = rows
        edited.move(fromOffsets: [index], toOffset: destination)
        save(edited)
    }

    private func save(_ rows: [HomeRow]) {
        withAnimation(Motion.spring(reduceMotion: reduceMotion)) {
            session.settings.homeRows.save(rows)
        }
    }
}

/// One row of Home Rows: what is in it now, its name, the titles it leads with and its switch.
private struct HomeRowToggle: View {
    let row: HomeRow
    @Binding var isOn: Bool

    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: Space.s3) {
                if !typeSize.isAccessibilitySize {
                    HomeRowPreview(row: row)
                        .opacity(row.shown ? 1 : 0.4)
                }
                VStack(alignment: .leading, spacing: Space.s1 / 2) {
                    Text(row.title)
                        .textRole(.headline)
                        .foregroundStyle(theme.ink)
                    Text(contents)
                        .textRole(.caption)
                        .foregroundStyle(theme.ink2)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                }
            }
            .padding(.vertical, Space.s1)
        }
        .tint(theme.accent)
        .accessibilityIdentifier("homeRows.\(row.id)")
    }

    private var contents: String {
        let titles = row.hub.items.prefix(3).map(\.posterTitle)
        return titles.isEmpty ? "Empty right now" : titles.joined(separator: ", ")
    }
}

/// A row's first posters fanned out, or for Continue Watching its first card, so a row is recognised
/// by what is in it.
private struct HomeRowPreview: View {
    let row: HomeRow

    static let size = CGSize(width: 64, height: 48)
    private static let poster = CGSize(width: 32, height: 48)
    private static let card = CGSize(width: 64, height: 36)
    private static let radius = Radius.inner(Radius.control, inset: 6)
    /// The clear gap that parts overlapping posters.
    private static let gap: CGFloat = 2

    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if let first = row.hub.items.first, row.isContinueWatching {
                art(first.cardArtPath, size: Self.card)
            } else if row.hub.items.isEmpty {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .fill(theme.trackOff)
                    .frame(width: Self.poster.width, height: Self.poster.height)
                    .overlay {
                        Image(systemName: "rectangle.stack")
                            .font(.caption)
                            .foregroundStyle(theme.ink2)
                    }
            } else {
                let items = Array(row.hub.items.prefix(3))
                ZStack(alignment: .leading) {
                    ForEach(Array(items.enumerated().reversed()), id: \.element.id) { index, item in
                        art(item.posterPath, size: Self.poster)
                            .background {
                                RoundedRectangle(cornerRadius: Self.radius + Self.gap, style: .continuous)
                                    .padding(-Self.gap)
                                    .blendMode(.destinationOut)
                            }
                            .offset(x: CGFloat(index) * Self.poster.width / 2)
                    }
                }
                .compositingGroup()
            }
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .leading)
        .accessibilityHidden(true)
    }

    private func art(_ path: String?, size: CGSize) -> some View {
        PlexArtView(path: path, size: size)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
    }
}

/// Home Rows in a sheet over Home: at half height Home stays in view above it and follows each change.
struct EditHomeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var detent = PresentationDetent.medium

    var body: some View {
        NavigationStack {
            HomeRowsView(onCanvas: detent == .large || verticalSizeClass == .compact)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("homeRows.done")
                    }
                }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        // Scrolling the rows keeps the half height, so Home stays in view; the grabber goes full height.
        .presentationContentInteraction(.scrolls)
    }
}
