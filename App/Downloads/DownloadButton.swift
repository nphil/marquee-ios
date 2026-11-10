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

private struct DownloadQualityChoices: View {
    let item: PlexMetadata
    let mediaIndex: Int
    @Environment(AppSession.self) private var session

    var body: some View {
        ForEach(DownloadQuality.choices, id: \.self) { quality in
            Button {
                Task { await session.downloads.enqueue(item: item, quality: quality, mediaIndex: mediaIndex, capabilities: await session.player.capabilities.current()) }
            } label: {
                if quality == session.downloads.settings.quality {
                    Label(quality.title, systemImage: "checkmark")
                } else {
                    Text(quality.title)
                }
            }
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
    /// Asks before removing a download; set by `removeDownloadConfirmation()`.
    @Entry var confirmDownloadRemoval: @MainActor (DownloadRecord) -> Void = { _ in }
}

/// "Remove Download?" for every remove button below it, which call `confirmDownloadRemoval`.
private struct RemoveDownloadConfirmation: ViewModifier {
    @Environment(AppSession.self) private var session
    @State private var removing: DownloadRecord?

    func body(content: Content) -> some View {
        content
            .environment(\.confirmDownloadRemoval) { removing = $0 }
            .confirmationDialog("Remove Download?", isPresented: Binding(
                get: { removing != nil },
                set: { if !$0 { removing = nil } }
            ), titleVisibility: .visible, presenting: removing) { record in
                Button("Remove Download", role: .destructive) { session.downloads.remove(record.id) }
            } message: { record in
                Text("Remove \(record.title) from this iPhone?")
            }
    }
}

extension View {
    func removeDownloadConfirmation() -> some View { modifier(RemoveDownloadConfirmation()) }
}
