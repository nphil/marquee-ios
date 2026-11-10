import MarqueeCore
import SwiftUI

struct DownloadsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @State private var removing: DownloadRecord?

    var body: some View {
        List {
            if session.downloads.records.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle", description: Text("Download a movie or episode to watch it without a connection."))
                    .listRowBackground(Color.clear)
            } else {
                ForEach(session.downloads.records) { record in
                    row(record)
                }
                .listRowBackground(theme.sheet)
            }
        }
        .themedList(theme)
        .navigationTitle("Downloads")
        .confirmationDialog("Remove Download?", isPresented: Binding(
            get: { removing != nil },
            set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible, presenting: removing) { record in
            Button("Remove Download", role: .destructive) { session.downloads.remove(record.id) }
        } message: { record in
            Text("Remove \(record.title) from this iPhone?")
        }
    }

    private func row(_ record: DownloadRecord) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Space.s1) {
                    if let show = record.showTitle {
                        Text(show).textRole(.caption).foregroundStyle(theme.ink2)
                    }
                    Text(record.title).textRole(.headline).foregroundStyle(theme.ink)
                        .accessibilityIdentifier("downloads.row.\(record.ratingKey)")
                    Text(status(record)).textRole(.caption).foregroundStyle(theme.ink2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if record.phase == .done {
                    Button { session.playDownload(record) } label: {
                        Image(systemName: "play.fill")
                    }
                    .accessibilityLabel("Play \(record.title)")
                    .accessibilityIdentifier("downloads.play.\(record.id)")
                } else if record.phase.isActive {
                    Button { session.downloads.pause(record.id) } label: {
                        Image(systemName: "pause.fill")
                    }
                    .accessibilityLabel("Pause \(record.title)")
                    .accessibilityIdentifier("downloads.pause.\(record.id)")
                } else {
                    Button { session.downloads.resume(record.id) } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Resume \(record.title)")
                    .accessibilityIdentifier("downloads.resume.\(record.id)")
                }
                Button(role: .destructive) { removing = record } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Remove \(record.title)")
                .accessibilityIdentifier("downloads.remove.\(record.id)")
            }
            .buttonStyle(.borderless)
            if record.phase != .done, let fraction = record.fraction {
                ProgressView(value: fraction)
                    .accessibilityLabel("Download progress")
            }
        }
        .padding(.vertical, Space.s1)
    }

    private func status(_ record: DownloadRecord) -> String {
        switch record.phase {
        case .waiting: "Waiting"
        case .converting:
            record.conversion?.progress.map { "Converting · \(Int($0 * 100))%" } ?? "Converting"
        case .downloading:
            record.fraction.map { "Downloading · \(Int($0 * 100))%" } ?? "Downloading"
        case .paused: "Paused"
        case .failed(let reason): "Failed · \(reason)"
        case .done: "Downloaded · \(record.quality.title)"
        }
    }
}
