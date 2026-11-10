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
                ForEach(DownloadQuality.choices, id: \.self) { quality in
                    Button {
                        Task { await session.downloads.enqueue(item: item, quality: quality, mediaIndex: mediaIndex) }
                    } label: {
                        if quality == session.downloads.settings.quality {
                            Label(quality.title, systemImage: "checkmark")
                        } else {
                            Text(quality.title)
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.round)
            .accessibilityLabel("Download")
            .accessibilityIdentifier("detail.download")
        }
    }
}
