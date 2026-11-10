import MarqueeCore
import SwiftUI

/// Downloads, grouped as Netflix groups them: what is still on its way, shows with their episodes inside,
/// then movies; the iPhone's storage along the bottom. Select removes several at once.
struct DownloadsView: View {
    var body: some View {
        DownloadsContent()
            .downloadErrorAlert()
            .removeDownloadConfirmation()
    }
}

/// Its own view: the environment set by `removeDownloadConfirmation()` reaches views below it, not the one
/// it modifies.
private struct DownloadsContent: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme

    var body: some View {
        let records = session.downloads.records
        let library = DownloadLibrary(records)
        List {
            if !library.unfinished.isEmpty {
                Section {
                    ForEach(library.unfinished) { record in
                        DownloadRow(record: record)
                    }
                } header: {
                    DownloadSectionTitle(title: "Downloading")
                }
            }
            if !library.shows.isEmpty {
                Section {
                    ForEach(library.shows) { show in
                        DownloadShowRow(show: show)
                    }
                } header: {
                    DownloadSectionTitle(title: "Shows")
                }
            }
            if !library.movies.isEmpty {
                Section {
                    ForEach(library.movies) { record in
                        DownloadRow(record: record)
                    }
                } header: {
                    DownloadSectionTitle(title: "Movies")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollHeader()
        .tabBarFollowsScroll()
        .environment(\.defaultMinListRowHeight, Size.rowMin)
        .background(theme.canvas)
        .overlay {
            if records.isEmpty {
                EmptyState(
                    title: "No Downloads",
                    message: "Download a movie or episode to watch it without a connection.",
                    systemImage: "arrow.down.circle"
                )
            }
        }
        .navigationTitle("Downloads")
        .toolbarTitleDisplayMode(.inlineLarge)
        .selectingDownloads(records) {
            if !records.isEmpty { DownloadStorageBar() }
        }
    }
}

/// A heading over a group of downloads.
struct DownloadSectionTitle: View {
    let title: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(title)
            .textRole(.headline)
            .foregroundStyle(theme.ink)
            .accessibilityAddTraits(.isHeader)
    }
}
