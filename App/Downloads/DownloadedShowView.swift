import MarqueeCore
import SwiftUI

/// One show's downloads: the finished episodes on this iPhone and any still on their way, by season.
struct DownloadedShowView: View {
    let showID: String

    var body: some View {
        DownloadedShowContent(showID: showID)
            .downloadErrorAlert()
            .removeDownloadConfirmation()
    }
}

/// Its own view: the environment set by `removeDownloadConfirmation()` reaches views below it, not the one
/// it modifies.
private struct DownloadedShowContent: View {
    let showID: String

    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// A run of the show's episodes with one season number.
    private struct Season: Identifiable {
        let id: Int
        let title: String
        var records: [DownloadRecord]
    }

    var body: some View {
        let show = DownloadLibrary(session.downloads.records).show(showID)
        let groups = seasons(of: show)
        List {
            // A show kept in one piece goes without a season's name.
            if groups.count > 1 {
                ForEach(groups) { season in
                    Section {
                        rows(season.records)
                    } header: {
                        DownloadSectionTitle(title: season.title)
                    }
                }
            } else {
                rows(groups.first?.records ?? [])
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollHeader()
        .tabBarFollowsScroll()
        .environment(\.defaultMinListRowHeight, Size.rowMin)
        .background(theme.canvas)
        .navigationTitle(show?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .selectingDownloads(show?.records ?? [])
        // The last download of the show went: nothing is left to show.
        .onChange(of: show == nil) { _, gone in
            if gone { dismiss() }
        }
    }

    private func rows(_ records: [DownloadRecord]) -> some View {
        ForEach(records) { record in
            DownloadRow(record: record, inShow: true)
        }
    }

    /// The records come by season and episode, so a season is a run of them with one number.
    private func seasons(of show: DownloadShow?) -> [Season] {
        var seasons: [Season] = []
        for record in show?.records ?? [] {
            let number = record.seasonIndex ?? -1
            if seasons.last?.id == number {
                seasons[seasons.count - 1].records.append(record)
            } else {
                seasons.append(Season(id: number, title: Self.title(of: record.seasonIndex), records: [record]))
            }
        }
        return seasons
    }

    private static func title(of season: Int?) -> String {
        guard let season else { return "Episodes" }
        return season == 0 ? "Specials" : "Season \(season)"
    }
}
