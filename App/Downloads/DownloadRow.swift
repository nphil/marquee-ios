import MarqueeCore
import SwiftUI

/// What a tap on a download does, by what the download is doing: a finished one plays, one on its way
/// pauses, a paused one resumes and a failed one tries again.
enum DownloadAction {
    case play, pause, resume, retry

    init(_ phase: DownloadRecord.Phase) {
        switch phase {
        case .done: self = .play
        case .waiting, .converting, .downloading: self = .pause
        case .paused: self = .resume
        case .failed: self = .retry
        }
    }

    var title: String {
        switch self {
        case .play: "Play Download"
        case .pause: "Pause Download"
        case .resume: "Resume Download"
        case .retry: "Try Again"
        }
    }

    /// For a swipe action, where the row already says what it is.
    var shortTitle: String {
        switch self {
        case .play: "Play"
        case .pause: "Pause"
        case .resume: "Resume"
        case .retry: "Try Again"
        }
    }

    var symbol: String {
        switch self {
        case .play: "play.fill"
        case .pause: "pause.fill"
        case .resume, .retry: "arrow.clockwise"
        }
    }

    var hint: String {
        switch self {
        case .play: "Plays the download"
        case .pause: "Pauses the download"
        case .resume: "Resumes the download"
        case .retry: "Tries the download again"
        }
    }

    /// `downloads.<this>.<id>` on the row's main button.
    var identifier: String {
        switch self {
        case .play: "downloads.play"
        case .pause: "downloads.pause"
        case .resume, .retry: "downloads.resume"
        }
    }

    @MainActor
    func perform(_ record: DownloadRecord, in session: AppSession) {
        switch self {
        case .play: session.playDownload(record)
        case .pause: session.downloads.pause(record.id)
        case .resume, .retry: session.downloads.resume(record.id)
        }
    }
}

/// One download (DESIGN §8.4's episode row, kept offline): the still with its progress, the title and
/// where it belongs, then size, resolution and quality, and what it is doing until it is finished. A tap
/// does what `DownloadAction` says; Remove is in a swipe, the More menu and the context menu. In Select
/// mode the whole row ticks instead.
struct DownloadRow: View {
    let record: DownloadRecord
    /// On its show's page, where the show is known: an episode's number leads its title and the show's
    /// name is left out.
    var inShow = false

    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.confirmDownloadRemoval) private var confirmRemoval
    @Environment(\.downloadSelection) private var selection

    private static let still = CGSize(width: 128, height: 72)

    private var action: DownloadAction { DownloadAction(record.phase) }
    private var hold: DownloadHold? { session.downloads.hold(for: record) }

    var body: some View {
        row
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("downloads.row.\(record.id)")
            .listRowBackground(theme.canvas)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: Space.s2, leading: Space.inset, bottom: Space.s2, trailing: Space.inset))
            .swipeActions(edge: .trailing, allowsFullSwipe: false) { trailingActions }
            .contextMenu {
                if selection == nil { DownloadRecordMenu(record: record) }
            }
    }

    @ViewBuilder
    private var row: some View {
        if let selection {
            Button {
                selection.toggle([record.id])
            } label: {
                HStack(spacing: Space.s1) {
                    DownloadTick(tick: selection.tick([record.id]))
                    content
                }
            }
            .buttonStyle(PressButtonStyle(cornerRadius: Radius.row))
            .accessibilityLabel(spoken)
            .accessibilityAddTraits(selection.picked.contains(record.id) ? .isSelected : [])
        } else {
            VStack(alignment: .leading, spacing: Space.s2) {
                HStack(alignment: .top, spacing: Space.s1) {
                    Button {
                        action.perform(record, in: session)
                    } label: {
                        content
                    }
                    .buttonStyle(PressButtonStyle(cornerRadius: Radius.row))
                    .accessibilityLabel(spoken)
                    .accessibilityHint(action.hint)
                    .accessibilityIdentifier("\(action.identifier).\(record.id)")
                    Menu {
                        DownloadRecordMenu(record: record)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(theme.ink2)
                            .frame(width: Size.target, height: Size.target)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("More for \(record.title)")
                    .accessibilityIdentifier("downloads.more.\(record.id)")
                }
                if hold == .wifi {
                    // Under the details, outside the row's own button, which would swallow its tap.
                    Button("Download on Cellular") { session.downloads.settings.cellular = true }
                        .buttonStyle(.tonal)
                        .accessibilityHint("Allows downloads over cellular data")
                        .accessibilityIdentifier("downloads.cellular.\(record.id)")
                        .padding(.leading, typeSize.isAccessibilitySize ? 0 : Self.still.width + Space.s3)
                }
            }
        }
    }

    @ViewBuilder
    private var trailingActions: some View {
        if selection == nil {
            Button("Remove", systemImage: "trash", role: .destructive) { confirmRemoval(record) }
                .tint(theme.danger)
            if action != .play {
                Button(action.shortTitle, systemImage: action.symbol) { action.perform(record, in: session) }
                    .tint(theme.accent)
            }
        }
    }

    private var content: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s2))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Space.s3))
        let progress = record.phase == .done ? record.watchedFraction : DownloadText.progress(record)
        return layout {
            VStack(spacing: Space.s1) {
                LocalArtView(
                    file: session.downloads.store.stillFile(for: record),
                    size: Self.still,
                    placeholder: record.type == .episode ? "tv" : "film"
                )
                .overlay { badge }
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                ProgressBar(value: progress ?? 0)
                    .opacity(progress == nil ? 0 : 1)
            }
            .frame(width: Self.still.width)
            details
        }
        .frame(minHeight: Size.rowMin, alignment: .top)
        .contentShape(Rectangle())
    }

    private var spoken: String {
        DownloadText.spoken(record, named: !inShow, hold: hold)
    }

    /// What a tap does, on the still: a solid canvas circle with an ink glyph, never glass (DESIGN §8.1).
    private var badge: some View {
        Image(systemName: action.symbol)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(theme.ink)
            .frame(width: Space.s7, height: Space.s7)
            .background(theme.canvas, in: Circle())
            .accessibilityHidden(true)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            Text(DownloadText.title(record, numbered: inShow))
                .textRole(.headline)
                .foregroundStyle(theme.ink)
            if let line = DownloadText.line(record, named: !inShow) {
                Text(line)
                    .textRole(.label)
                    .foregroundStyle(theme.ink2)
                    .monospacedDigit()
            }
            if let state = DownloadText.state(record, hold: hold) {
                switch (record.phase, hold) {
                case (.failed, _):
                    StatusLine(symbol: "exclamationmark.circle.fill", tint: theme.danger, text: state)
                        .textRole(.caption)
                case (_, .wifi):
                    StatusLine(symbol: "wifi", tint: theme.info, text: state)
                        .textRole(.caption)
                case (_, .unreachable):
                    StatusLine(symbol: "exclamationmark.triangle.fill", tint: theme.warning, text: state)
                        .textRole(.caption)
                default:
                    Text(state)
                        .textRole(.caption)
                        .foregroundStyle(theme.ink)
                        .monospacedDigit()
                }
            }
            Text(DownloadText.facts(record))
                .textRole(.caption)
                .foregroundStyle(theme.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
    }
}

/// What can be done with one download, in its More menu and its context menu.
struct DownloadRecordMenu: View {
    let record: DownloadRecord

    @Environment(AppSession.self) private var session
    @Environment(\.confirmDownloadRemoval) private var confirmRemoval

    var body: some View {
        let action = DownloadAction(record.phase)
        Button(action.title, systemImage: action.symbol) { action.perform(record, in: session) }
        Button("Remove Download", systemImage: "trash", role: .destructive) { confirmRemoval(record) }
    }
}
