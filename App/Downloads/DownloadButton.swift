import MarqueeCore
import SwiftUI

struct DownloadButton: View {
    let item: PlexMetadata
    let mediaIndex: Int
    @Environment(AppSession.self) private var session

    private var record: DownloadRecord? {
        session.downloads.records.first { $0.ratingKey == item.ratingKey }
    }

    var body: some View {
        if let record {
            Menu {
                if record.phase == .done {
                    Button("Play Download", systemImage: "play.fill") { session.playDownload(record) }
                } else if record.phase.isActive {
                    Button("Pause Download", systemImage: "pause.fill") { session.downloads.pause(record.id) }
                } else {
                    Button("Resume Download", systemImage: "arrow.clockwise") { session.downloads.resume(record.id) }
                }
            } label: {
                Image(systemName: record.phase == .done ? "checkmark.circle.fill" : "arrow.down.circle.fill")
            }
            .buttonStyle(.round)
            .accessibilityLabel(record.phase == .done ? "Downloaded" : "Download in progress")
            .accessibilityIdentifier("detail.download")
        } else {
            Menu {
                DownloadQualityChoices(item: item, mediaIndex: mediaIndex)
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.round)
            .accessibilityLabel("Download")
            .accessibilityIdentifier("detail.download")
            // HomeLabber's scores and the show's genres, so the sizes are ready when the menu opens.
            .task(id: item.ratingKey) { await session.downloads.prepareChoices(for: item) }
        }
    }
}

/// The same choices as the round button, in the three-dot menus: Download with its quality choices, or
/// the state of the download already there.
struct DownloadMenuItems: View {
    let item: PlexMetadata
    let mediaIndex: Int
    @Environment(AppSession.self) private var session
    @Environment(\.confirmDownloadRemoval) private var confirmRemoval

    var body: some View {
        if let record = session.downloads.records.first(where: { $0.ratingKey == item.ratingKey }) {
            if record.phase == .done {
                Button("Play Download", systemImage: "play.fill") { session.playDownload(record) }
            } else if record.phase.isActive {
                Button("Pause Download", systemImage: "pause.fill") { session.downloads.pause(record.id) }
            } else {
                Button("Resume Download", systemImage: "arrow.clockwise") { session.downloads.resume(record.id) }
            }
            Button("Remove Download", systemImage: "trash", role: .destructive) { confirmRemoval(record) }
        } else {
            Menu("Download", systemImage: "arrow.down.circle") {
                DownloadQualityChoices(item: item, mediaIndex: mediaIndex)
            }
        }
    }
}

/// "Download Season" or "Download Show": every episode not already downloaded or queued, at the default quality.
struct DownloadEpisodesItem: View {
    let item: PlexMetadata
    @Environment(AppSession.self) private var session

    var body: some View {
        Button(item.type == .show ? "Download Show" : "Download Season", systemImage: "arrow.down.circle") {
            Task { await session.downloads.enqueueEpisodes(under: item, capabilities: await session.player.capabilities.current()) }
        }
    }
}

/// Original, then High, Medium and Low as the server converts them, each with its picture size and
/// about how large it comes to, and under a conversion whether that is measured or estimated. The
/// default quality's choice is ticked.
private struct DownloadQualityChoices: View {
    let item: PlexMetadata
    let mediaIndex: Int
    @Environment(AppSession.self) private var session

    var body: some View {
        let downloads = session.downloads
        let capabilities = session.player.capabilities.hardware.map(PlaybackCapabilities.device)
        if let plan = downloads.plan(for: item, mediaIndex: mediaIndex, capabilities: capabilities) {
            let ticked = plan.option(for: downloads.settings.quality)?.id
            ForEach(plan.options) { option in
                choice(option.quality, id: option.id, title: DownloadText.choice(option), detail: DownloadText.basis(option), ticked: option.id == ticked)
            }
        } else {
            ForEach(DownloadQuality.choices, id: \.self) { quality in
                choice(quality, id: nil, title: quality.title, detail: nil, ticked: quality == downloads.settings.quality)
            }
        }
    }

    private func choice(_ quality: DownloadQuality, id: String?, title: String, detail: String?, ticked: Bool) -> some View {
        Button {
            Task {
                await session.downloads.enqueue(
                    item: item, quality: quality, choice: id, mediaIndex: mediaIndex, capabilities: await session.player.capabilities.current()
                )
            }
        } label: {
            if ticked {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
            if let detail { Text(detail) }
        }
    }
}

/// `DownloadCenter.error` had no screen: a refused Download tap changed nothing the user could see.
private struct DownloadErrorAlert: ViewModifier {
    @Environment(AppSession.self) private var session

    func body(content: Content) -> some View {
        let downloads = session.downloads
        content.alert("Download Problem", isPresented: Binding(
            get: { downloads.error != nil },
            set: { if !$0 { downloads.error = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloads.error ?? "")
        }
    }
}

extension View {
    func downloadErrorAlert() -> some View { modifier(DownloadErrorAlert()) }
}

extension EnvironmentValues {
    /// Asks before removing downloads; set by `removeDownloadConfirmation()`.
    @Entry var confirmDownloadRemoval: ConfirmDownloadRemoval = ConfirmDownloadRemoval { _ in }
}

struct ConfirmDownloadRemoval {
    let ask: @MainActor ([DownloadRecord]) -> Void

    @MainActor
    func callAsFunction(_ record: DownloadRecord) {
        ask([record])
    }

    @MainActor
    func callAsFunction(_ records: [DownloadRecord]) {
        ask(records)
    }
}

/// "Remove Download?" for every remove button below it, which call `confirmDownloadRemoval`, for one
/// download or several at once.
private struct RemoveDownloadConfirmation: ViewModifier {
    @Environment(AppSession.self) private var session
    @State private var asking: [DownloadRecord] = []
    @State private var isAsking = false

    private var title: String {
        asking.count > 1 ? "Remove \(asking.count) Downloads?" : "Remove Download?"
    }

    func body(content: Content) -> some View {
        content
            .environment(\.confirmDownloadRemoval, ConfirmDownloadRemoval { records in
                guard !records.isEmpty else { return }
                asking = records
                isAsking = true
            })
            .confirmationDialog(title, isPresented: $isAsking, titleVisibility: .visible, presenting: asking) { records in
                Button(records.count > 1 ? "Remove \(records.count) Downloads" : "Remove Download", role: .destructive) {
                    for record in records { session.downloads.remove(record.id) }
                }
            } message: { records in
                Text(records.count > 1 ? "Remove \(records.count) downloads from this iPhone?" : "Remove \(records.first?.title ?? "this download") from this iPhone?")
            }
    }
}

extension View {
    func removeDownloadConfirmation() -> some View { modifier(RemoveDownloadConfirmation()) }
}
