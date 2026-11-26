import MarqueeCore
import SwiftUI

struct ShowRecordingAirings: View {
    let title: String
    @State private var store: LiveTVStore
    @State private var selection: ProgrammeSelection?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    init(title: String, library: PlexLibrary, profile: String?) {
        self.title = title
        _store = State(initialValue: LiveTVStore(library: library, serverName: library.server.name, profile: profile))
    }

    private var matches: [ProgrammeSelection] {
        store.guide.channels.flatMap { channel in
            (store.guide.airings[channel.id] ?? []).compactMap { airing -> ProgrammeSelection? in
                guard airing.end > store.now, airing.title.localizedCaseInsensitiveCompare(title) == .orderedSame else { return nil }
                return ProgrammeSelection(airing: airing, channel: channel)
            }
        }.sorted { $0.airing.start < $1.airing.start }
    }

    var body: some View {
        NavigationStack {
            List {
                switch store.phase {
                case .loading: ProgressView()
                case .failed(let reason): Text(reason)
                case .noDVR: Text("Live TV isn’t set up on this server.")
                case .ready:
                    let listings = matches
                    if listings.isEmpty { Text("No showing of \(title) in the loaded guide.") }
                    ForEach(listings) { match in
                        Button { selection = match } label: {
                            VStack(alignment: .leading) {
                                Text(match.airing.episodeTitle ?? match.airing.title).textRole(.headline)
                                Text("\(LiveText.when(match.airing, now: store.now)) · \(match.channel.label)").textRole(.label)
                            }
                        }
                    }
                }
            }.themedList(theme).navigationTitle("Choose an airing").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
                .sheet(item: $selection) { ProgrammeSheet(store: store, selection: $0) }
                .task { await store.refresh() }
        }
    }
}
