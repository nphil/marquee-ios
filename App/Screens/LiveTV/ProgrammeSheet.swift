import MarqueeCore
import SwiftUI

/// An airing picked in the guide, for its programme sheet.
struct ProgrammeSelection: Identifiable, Hashable {
    let airing: LiveAiring
    let channel: LiveChannel

    var id: String { airing.id }
}

/// One airing in full (docs/LIVE-TV.md §6.9): art, title, episode, day, time, channel, tags and summary;
/// Watch while it is on; and, for a profile that may record, the ways the server offers to record it with
/// their start and end padding. A partial sheet keeps the system glass; at full height the content sits on
/// the canvas (DESIGN §6).
struct ProgrammeSheet: View {
    let store: LiveTVStore
    let selection: ProgrammeSelection
    /// Plays the channel; nil leaves Watch out.
    var watch: (@MainActor (LiveChannel) -> Void)?

    @Environment(ThemeStore.self) private var themes
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var detent: PresentationDetent = .medium
    @State private var choices: Choices = .loading
    @State private var draft: RecordingDraft?
    @State private var showsEditor = false
    @State private var working: Work?
    @State private var problem: String?
    @State private var confirmsStop = false

    private enum Choices: Equatable {
        case loading
        case ready([RecordOption])
        case failed
    }

    private enum Work: Equatable {
        case unschedule
    }

    private var airing: LiveAiring { selection.airing }
    private var channel: LiveChannel { selection.channel }
    private var now: Date { store.now }
    private var mark: RecordingMark? { store.mark(for: airing) }
    private var recordable: Bool { store.canRecord && airing.end > now }
    private var watchable: Bool { watch != nil && airing.isOn(at: now) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s4) {
                if let art = airing.art ?? airing.thumb {
                    Banner(path: art)
                }
                header
                if airing.isOn(at: now) {
                    ProgressLine(progress: airing.progress(at: now))
                }
                if let mark {
                    RecordStatusLine(mark: mark)
                }
                actions
                if let problem {
                    ProgrammeProblemLine(text: problem)
                }
                if let summary = airing.summary, !summary.isEmpty {
                    Text(summary)
                        .textRole(.body)
                        .foregroundStyle(theme.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Space.inset)
            .padding(.top, Space.s6)
            .padding(.bottom, Space.s6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(detent == .large ? theme.canvas : .clear)
        .overlay(alignment: .topTrailing) {
            Button("Close", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .buttonStyle(.round)
                .padding(Space.s2)
                .accessibilityIdentifier("livetv.programme.close")
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .preferredColorScheme(themes.presentationScheme(for: theme))
        .task { await loadChoices() }
        .confirmationDialog("Stop recording \(airing.title)?", isPresented: $confirmsStop, titleVisibility: .visible) {
            Button("Stop Recording", role: .destructive) { unschedule() }
            if let recording = store.recordings.recording(of: airing), store.offersSeriesDeletion(recording) {
                Button("Stop and Delete the Series Rule", role: .destructive) { unschedule(deletingSeries: true) }
            }
        } message: {
            Text("The tuner is freed at once.")
        }
        .sheet(isPresented: $showsEditor) {
            if let draft {
                RecordingEditor(draft: draft, save: { submission in
                    try await store.record(submission.option, values: submission.values, airing: airing)
                })
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("livetv.programme")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            Text(airing.title)
                .textRole(.title)
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                // Clear of the close button when no banner sits above.
                .padding(.trailing, (airing.art ?? airing.thumb) == nil ? Size.target : 0)
            if let subtitle = LiveText.subtitle(airing) {
                Text(subtitle)
                    .textRole(.label)
                    .foregroundStyle(theme.ink2)
            }
            Text(airing.isOn(at: now) ? "\(LiveText.range(airing)) · \(LiveText.left(airing, at: now))" : LiveText.when(airing, now: now))
                .textRole(.label)
                .foregroundStyle(theme.ink2)
            channelLine
                .padding(.top, Space.s1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LiveText.spoken(channel, airing: airing, at: now, mark: nil))
        .accessibilityAddTraits(.isHeader)
    }

    /// Logo, number and call sign, then NEW, HD and the rating; the tags take their own row at
    /// accessibility sizes.
    private var channelLine: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s2))
            : AnyLayout(HStackLayout(spacing: Space.s2))
        return layout {
            HStack(spacing: Space.s2) {
                ChannelLogo(channel: channel, side: 28)
                Text(channel.label)
                    .textRole(.label)
                    .foregroundStyle(theme.ink)
            }
            HStack(spacing: Space.s1) {
                if airing.isNew { TagChip(text: "NEW") }
                if airing.isHD { TagChip(text: "HD") }
                if let rating = airing.contentRating, !rating.isEmpty { TagChip(text: rating) }
            }
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        if watchable || recordable {
            VStack(spacing: Space.s2) {
                if watchable, let watch {
                    Button {
                        watch(channel)
                    } label: {
                        Label("Watch", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.pill)
                    .accessibilityIdentifier("livetv.programme.watch")
                }
                if recordable {
                    recordActions
                }
            }
            .disabled(working != nil)
        }
    }

    @ViewBuilder
    private var recordActions: some View {
        switch mark {
        case nil:
            switch choices {
            case .loading:
                HStack(spacing: Space.s2) {
                    Capsule().fill(theme.trackOff).frame(height: Size.target)
                    Capsule().fill(theme.trackOff).frame(height: Size.target)
                }
                .accessibilityHidden(true)
            case .failed:
                HStack(spacing: Space.s3) {
                    Text("The ways to record didn't load.")
                        .textRole(.label)
                        .foregroundStyle(theme.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Try Again") {
                        choices = .loading
                        Task { await loadChoices() }
                    }
                    .buttonStyle(.tonal)
                }
            case .ready:
                if draft == nil {
                    Text("\(store.serverName) can't record this programme.")
                        .textRole(.label)
                        .foregroundStyle(theme.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Button("Record…") { showsEditor = true }
                        .buttonStyle(.pill)
                        .accessibilityIdentifier("livetv.programme.options")
                }
            }
        case .scheduled?:
            unscheduleButton("Cancel Recording", systemImage: "xmark")
        case .series?:
            unscheduleButton("Skip This Episode", systemImage: "forward.end")
        case .recording?:
            unscheduleButton("Stop Recording", systemImage: "stop.fill", confirm: true)
        case .failed?, .recorded?:
            EmptyView()
        }
    }

    private func unscheduleButton(_ title: String, systemImage: String, confirm: Bool = false) -> some View {
        Button {
            if confirm { confirmsStop = true } else { unschedule() }
        } label: {
            HStack(spacing: Space.s2) {
                if working == .unschedule {
                    ProgressView()
                        .tint(theme.ink)
                } else {
                    Image(systemName: systemImage)
                        .accessibilityHidden(true)
                }
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.tonal)
        .accessibilityIdentifier("livetv.programme.unschedule")
    }

    // MARK: Work

    private func loadChoices() async {
        guard recordable else { return }
        do {
            let options = try await store.recordOptions(for: airing)
            draft = RecordingDraft(airing: airing, channel: channel, options: options, libraries: await store.recordingLibraries())
            choices = .ready(options)
        } catch {
            choices = .failed
        }
    }

    private func unschedule(deletingSeries: Bool = false) {
        working = .unschedule
        problem = nil
        Task {
            do {
                try await store.unschedule(airing, deletingSeries: deletingSeries)
                Haptics.success()
            } catch {
                Haptics.error()
                problem = LiveText.recordingProblem(error, server: store.serverName)
            }
            working = nil
        }
    }
}

// MARK: - Parts

/// The airing's art across the sheet, cropped to a fixed height so the actions stay above the fold at
/// the medium detent.
private struct Banner: View {
    let path: String
    @Environment(\.theme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .overlay {
                GeometryReader { proxy in
                    PlexArtView(path: path, size: proxy.size, placeholder: "tv")
                }
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(theme.edge, lineWidth: 1) }
    }
}

/// The record state: its glyph in the role colour and the words in ink, with SERIES when a series rule
/// covers the airing (docs/LIVE-TV.md §6.10).
private struct RecordStatusLine: View {
    let mark: RecordingMark
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Space.s2) {
            RecordGlyph(mark: mark)
            Text(LiveText.status(mark))
                .textRole(.headline)
                .foregroundStyle(theme.ink)
            if mark == .series {
                TagChip(text: "SERIES")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LiveText.mark(mark) ?? "")
        .accessibilityIdentifier("livetv.programme.status")
    }
}

private struct ProgrammeProblemLine: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(theme.danger)
                .accessibilityHidden(true)
            Text(text)
                .textRole(.label)
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("livetv.programme.problem")
    }
}

/// A secondary pill beside or under the accent one: the raised glass fill with a 1 pt rim and an ink
/// label.
struct TonalButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TonalLabel(configuration: configuration)
    }
}

extension ButtonStyle where Self == TonalButtonStyle {
    static var tonal: TonalButtonStyle { TonalButtonStyle() }
}

private struct TonalLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .textRole(.headline)
            .foregroundStyle(theme.ink)
            .padding(.horizontal, Space.s5)
            .padding(.vertical, Space.s2)
            .frame(minHeight: Size.target)
            .background(theme.glassRaised, in: Capsule())
            .overlay { Capsule().strokeBorder(theme.edge, lineWidth: 1) }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
            .pressed(configuration.isPressed, in: Capsule())
    }
}

private extension String {
    /// "On time" from "on time".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
