import MarqueeCore
import SwiftUI

/// A show in the Downloads list: its poster, name, and how many finished episodes it keeps and what they
/// take. Opens the show's downloads; in Select mode it ticks all of its finished episodes at once.
struct DownloadShowRow: View {
    let show: DownloadShow

    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.downloadSelection) private var selection

    private static let poster = CGSize(width: 56, height: 84)

    var body: some View {
        row
            .accessibilityIdentifier("downloads.show.\(show.id)")
            .listRowBackground(theme.canvas)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: Space.s2, leading: Space.inset, bottom: Space.s2, trailing: Space.inset))
    }

    @ViewBuilder
    private var row: some View {
        if let selection {
            let ids = show.finished.map(\.id)
            Button {
                selection.toggle(ids)
            } label: {
                HStack(spacing: Space.s1) {
                    DownloadTick(tick: selection.tick(ids))
                    content
                }
            }
            .buttonStyle(PressButtonStyle(cornerRadius: Radius.row))
            .accessibilityLabel(spoken)
            .accessibilityAddTraits(selection.tick(ids) == .all ? .isSelected : [])
        } else {
            NavigationLink {
                DownloadedShowView(showID: show.id)
            } label: {
                content
            }
            .accessibilityLabel(spoken)
        }
    }

    private var content: some View {
        HStack(spacing: Space.s3) {
            LocalArtView(
                file: session.downloads.store.posterFile(for: show.poster),
                size: Self.poster,
                placeholder: "tv"
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(show.title)
                    .textRole(.headline)
                    .foregroundStyle(theme.ink)
                    .lineLimit(2)
                Text(summary(separator: " · "))
                    .textRole(.label)
                    .foregroundStyle(theme.ink2)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
        .frame(minHeight: Size.rowMin)
        .contentShape(Rectangle())
    }

    private var spoken: String {
        "\(show.title), \(summary(separator: ", "))"
    }

    /// "3 episodes · 4.2 GB".
    private func summary(separator: String) -> String {
        let count = show.finished.count
        return ["\(count) \(count == 1 ? "episode" : "episodes")", DownloadText.size(show.bytes)].joined(separator: separator)
    }
}
